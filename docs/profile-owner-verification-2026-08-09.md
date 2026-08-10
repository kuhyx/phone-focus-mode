# EnforcementRunner on-device verification (profile-owner harness)

Date: 2026-08-09. Device: Pixel 6a `23181JEGR08034`, Android 16 (SDK 36).

The Device Owner path is still blocked on a factory reset, so this run used a
removable managed profile as a stand-in: `pm create-user --profileOf 0
--managed` (user 12) → `dpm set-profile-owner` → `pm install-existing --user 12`.
Profile owner and device owner reach the same `DevicePolicyManager` calls, so
the wiring under test is identical; what differs is scope, recorded below.

## Verified

| Property                           | Method                                     | Result                                                                                               |
| ---------------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| Policy loads on device             | app status screen                          | 84 allowed (39 night), curfew 23:00-05:00, radius 150 m, 15 workout domains                          |
| Enforcement pass runs end-to-end   | tap "Run enforcement now"                  | `applied LOCATION_UNKNOWN: hid 3, restored 0`                                                        |
| Hide is real, not self-reported    | `dumpsys package <pkg>` per-user `hidden=` | `com.termux`, `org.breezyweather`, `de.duenndns.gmdice` all `hidden=true`                            |
| Hidden app is unreachable          | `am start --user 12 -n com.termux/...`     | `Error type 3 ... does not exist`                                                                    |
| Self-hide guard holds              | same dumpsys sweep                         | `com.kuhy.focus_owner` stayed `hidden=false`                                                         |
| **Hide survives reboot**           | `adb reboot` → re-check                    | all three still `hidden=true`                                                                        |
| Next pass is armed                 | `dumpsys alarm`                            | `*walarm*:com.kuhy.focus_owner/.EnforcementAlarmReceiver` present                                    |
| **Unhide restores access**         | after the fix below                        | `restored 3`; all `hidden=false`, launchable again                                                   |
| Non-exported service rejects shell | `am start-foreground-service`              | `Requires permission not exported from uid 1210324` — as designed; the UI button is the only trigger |

The reboot result is the one that matters: it is the property the whole Device
Owner design rests on, and it is the one `pm suspend` and `pm disable-user`
both fail.

## Not covered by this harness

- **The geofence.** Retried after real coordinates were provisioned (see
  below), and still not reachable: a freshly created work profile has its own
  location cache, which starts empty and stays empty because nothing in the
  profile requests a fix. `dumpsys location` showed
  `user 10: last location=null` against a valid `52.228948,20.951184` fix in
  user 0. `EnforcementRunner.lastKnownLocation()` therefore returned null and
  every pass resolved to `LOCATION_UNKNOWN` (fail-closed) regardless. Shell
  mock injection is blocked (`SecurityException: not allowed to perform
MOCK_LOCATION`) and `cmd location force-location-update` does not exist on
  this build. **The AWAY branch remains unexercised on hardware** and will
  only be testable under a real Device Owner in user 0.

  Note the earlier `run-as` failure was mine, not a platform limit: `run-as
--user N` works once the app has been launched in user N. Coordinates were
  successfully written into the profile's `filesDir` on the second attempt.

- **The full 373-package sweep.** The profile saw only the packages
  deliberately installed into it.
- **Persisted hysteresis.** `wasEnforcing()` starts fresh in a new profile.
- **System packages.** `com.google.android.dialer` is a system app, so
  `installedThirdPartyPackages()` filters it out; it did not exercise the
  allowlist branch as intended.

## The bug this run found: hidden apps could never be restored

Testing the restore path meant widening the allowlist to cover the three test
apps and re-running a pass. Expected `restored 3`. Observed:

```
applied LOCATION_UNKNOWN: hid 0, restored 0
```

with all three still `hidden=true`. The cause is that
`pm list packages --user 12 -3` returned _only_ `com.kuhy.focus_owner` — a
package hidden via `setApplicationHidden` is dropped from the default package
enumeration entirely, while remaining `installed=true hidden=true` and visible
under `pm list packages -u`.

`EnforcementRunner.installedThirdPartyPackages()` called
`getInstalledApplications(0)`. So once an app was hidden it left
`installedPackages`, which meant it could never appear in
`EnforcementDecision.packagesToShow`, which meant **nothing this app hid could
ever be unhidden again** — the exact failure the show-before-hide ordering in
`apply()` exists to prevent. Leaving home would not have restored anything.

Fix: query with `PackageManager.MATCH_UNINSTALLED_PACKAGES`. Re-verified on
device after the fix:

```
setApplicationHidden(de.duenndns.gmdice,false)=true
setApplicationHidden(org.breezyweather,false)=true
setApplicationHidden(com.termux,false)=true
applied LOCATION_UNKNOWN: hid 0, restored 3
```

All three then read `hidden=false`, reappeared in the default enumeration, and
`cmd package resolve-activity com.termux` resolved to `TermuxActivity` again.

The flag also admits packages that are uninstalled with data retained, which
would let `packagesToHide` contain ghosts. Measured on this device:
`pm list packages -3` and `pm list packages -u -3` both return 49, so there are
none. `apply()` wraps both bridge calls in `runCatching` regardless, so a ghost
would be a no-op rather than a crash.

## Second finding: the self-hide guard is not redundant

`EnforcementRunner.kt:79-80` comments the self-hide check as defence in depth —
_"the policy already refuses to hide these"_. Measured against the committed
policy, it does not: `com.kuhy.focus_owner` is absent from `allowed_packages`,
absent from `night_allowed_packages`, and matches none of the 44
`never_disable_prefixes`. The decision layer therefore places the app in
`packagesToHide` on **every** enforcing pass, and the `pkg ==
context.packageName` check at line 81 is the _only_ thing stopping the app from
hiding itself — which would remove the escape hatch and the "Run enforcement
now" trigger together.

Fix belongs in the exporter (`python_pkg/focus_policy/export.py`), not a
hand-edit of the asset, so the guarantee is generated rather than remembered.
The line-81 check should stay either way; only the comment is wrong.

## Wiring gap found

`EnforcementRunner.decide()` hardcodes `workoutActive = false`
(`EnforcementRunner.kt:57`). The decision layer honours the flag
(`EnforcementDecision.kt:83`), but nothing feeds it in the Kotlin path — and
the Kotlin path is the one that runs at alarm time, since a background service
has no Flutter engine. **The workout unblock is currently dead in the deployed
path.** Not fixed in this session.

The Dart side is thinner than it looks. `lib/workout_signal.dart` defines
`ManualWorkoutSignal`, `GuardedWorkoutSignal` and `CombinedWorkoutSignal`, all
unit-tested, but none is constructed anywhere in `lib/` — and there is **no
Health Connect integration at all**: no `androidx.health` dependency, no
`android.permission.health.*` in the manifest, no query. `'health_connect'`
appears only as a fixture string in `test/workout_signal_test.dart`. Wiring
Health Connect is a from-scratch build, not a port.

It is, however, a viable one. Measured on device: `com.stronglifts.app` holds
`android.permission.health.WRITE_EXERCISE`, `WRITE_ACTIVE_CALORIES_BURNED`,
`WRITE_WEIGHT`, `WRITE_HEIGHT` and the matching `READ_*` grants, all
`granted=true`, and `com.google.android.apps.healthdata` is installed. So the
workout data the rooted system used to read out of StrongLifts' SQLite file is
reachable through a supported API, which is the natural replacement for that
lost signal.

## Home coordinates: placeholder found and replaced

`config_secrets.sh` still held `REDACTED_LAT`/`REDACTED_LON`, so the policy
asset could not be regenerated. Real coordinates were taken from the Pixel 6a's
own fix rather than a map lookup — `52.228948, 20.951184`, network provider,
`hAcc=21.7 m`, consistent across the fused and network providers.

That surfaced a second staleness problem: the coordinates already provisioned
into the app's private storage were `52.2297, 21.0122` — Warsaw city centre, a
placeholder. **4156 m from the real location, against a 150 m radius**, so the
geofence would have read as permanently away from home. Re-provisioned via
`scripts/push_home_location.sh` and verified on device.

Regenerating `assets/policy.json` then confirmed the exporter fix end-to-end:
`com.kuhy.focus_owner` now appears in both allowlists. The regeneration also
picked up `com.kuhy.untools`, which was already in `config.sh:365` — the
committed asset was simply stale.

The committed asset stays redacted: `latitude: null`, `longitude: null`, and
zero occurrences of the real values. The unredacted export (stdout only, used
by the provisioning script) carries them.

## Teardown (done)

`pm remove-user 12` → `Success: removed user`; a clean build (committed policy
asset, no widened allowlist) reinstalled into user 0; staged
`/data/local/tmp/home_location.json` removed. Verified afterwards:

- `pm list users` → user 0 only
- `Device Owner Type: -1`, no profile owner
- `com.termux`, `org.breezyweather`, `de.duenndns.gmdice`,
  `com.stronglifts.app` all `hidden=false` in user 0

Three `EnforcementAlarmReceiver` alarms remain registered by the user-0
instance. They are inert: `DevicePolicyBridge.setApplicationHidden` returns
early when the caller is neither device owner nor profile owner, which user 0
is not.
