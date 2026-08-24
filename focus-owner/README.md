# focus_owner

Device Owner app that enforces focus mode on an unrooted Pixel 6a
(`23181JEGR08034`). It hides apps by GPS distance from home, plus a 23:00–05:00
night curfew, and keeps YouTube hidden everywhere.

**Live and enforcing.** It is provisioned as device owner, pins RethinkDNS as an
always-on VPN with lockdown, and blocks its own uninstall while enforcing.

## How a decision is made

One pass runs every 15 minutes (and at each curfew boundary), from
`EnforcementService` → `EnforcementRunner.decide()` → `EnforcementDecision.evaluate()`.

There are **five** outcomes, and only the first two look different from the
outside — which is exactly what made this hard to debug before the status
screen existed:

| Reason             | What it does                                                                        |
| ------------------ | ----------------------------------------------------------------------------------- |
| `AWAY`             | Hides only `always_blocked_packages`; everything else is available.                 |
| `AT_HOME`          | Full day allowlist sweep.                                                           |
| `CURFEW`           | Full sweep against the shorter night allowlist.                                     |
| `LOCATION_UNKNOWN` | **Identical sweep to `AT_HOME`** — fail-closed, so losing GPS is not an off switch. |
| `WORKOUT`          | As at home, plus the workout exemptions.                                            |

Plus a sixth state that is not a reason: **no home configured**, which makes the
fence answer "inside" everywhere and so enforces everywhere. The status screen
renders that case explicitly rather than letting it read as `AT_HOME`.

`always_blocked_packages` (YouTube, YouTube Music, Chrome) are exempt from every
branch including `AWAY` and `WORKOUT`, so leaving the house cannot restore them.

## Diagnosing it

**Use the in-app screen, not adb.** Neither adb route works here:

- `run-as` returns `package not debuggable` — device owner requires a release
  build, and making it debuggable would let anyone with adb edit this app's
  state, which is the bypass the whole design exists to close.
- logcat rotates. Measured 2026-08-14: `adb logcat -d -s FocusOwner:V` came back
  **empty** while `dumpsys alarm` showed 82 alarms had fired.

So the durable record is `filesDir/enforcement_log.jsonl`, written by
`EnforcementLog` and read back over the platform channel. The main screen shows
the latest pass — reason, distance vs the fence, fix age/provider/accuracy,
curfew state, and every hidden app with the rule that hid it — and **Debug log**
shows the history. It never records coordinates: distance in metres is enough to
debug a geofence, and this is a home address.

Useful fields when something looks wrong:

- `fix.outcome` — `CACHED_FRESH` / `ACTIVE_OK` / `TIMEOUT` / `NO_PERMISSION` /
  `NO_PROVIDER`. Distinguishes "no fix at the office" from "fuzzed fix at home".
- `fix.accuracy_m` — tens of metres means precise location is live. Hundreds or
  thousands means the app is being fed fuzzed coarse location and the 150 m
  fence cannot be trusted.
- `failure` — set on passes that decided nothing (not provisioned, unreadable
  policy), which otherwise leave no trace at all.

## Location

The geofence needs `ACCESS_FINE_LOCATION`; coarse is fuzzed to a ~1–2 km grid on
Android 12+, against a 150 m radius. The app **self-grants** fine, coarse and
background location every pass via `setPermissionGrantState` (device owner needs
no prompt), and calls `setLocationEnabled(true)`.

Each pass actively requests a fix rather than reading whatever another app
cached, bounded by `ACQUIRE_TIMEOUT_MS` (20 s) and run inside a
`location`-typed foreground service — background location delivery is throttled
too hard otherwise. A cached fix younger than `FRESH_WINDOW_MS` (30 min) is used
as-is; anything older is treated as no fix and fails closed. That window is
deliberately **longer than the 15-minute cadence**: a shorter one would mark the
newest available cache stale on every pass of an idle phone and block everything.

## Policy

Generated from `phone_focus_mode/config.sh`, never hand-edited:

```bash
cd ~/testsAndMisc
python3 -m python_pkg.focus_policy \
  --config phone_focus_mode/config.sh \
  --output focus_owner/assets/policy.json --redact-home
```

`--redact-home` is required — the committed asset must keep `latitude`/
`longitude` null. Real coordinates live only in app-private storage, written by
"Set home to current location" in the app.

Allowlists are exact-match, plus `allowed_prefixes` / `night_allowed_prefixes`
for apps that ship as a package family (Tachiyomi installs every source as its
own apk). Prefixes match whole labels, so `eu.kanade.tachiyomi` covers
`eu.kanade.tachiyomi.extension.all.mangadex` but not `eu.kanade.tachiyomisomething`.

**Sweepable is not the same as hideable.** `blockable_system_packages` decides
which `FLAG_SYSTEM` packages are _eligible for a decision_; `isAllowed` is what
then protects them. Removing an allowed system package from that list does not
protect it, it **freezes** it in whatever state it was last left in — it lands
in neither `packagesToHide` nor `packagesToShow`. Play Store is the live example.

## Build and verify

```bash
cd ~/testsAndMisc/focus_owner
flutter analyze && flutter test
JAVA_HOME=/usr/lib/jvm/java-21-openjdk (cd android && ./gradlew :app:testDebugUnitTest)
JAVA_HOME=/usr/lib/jvm/java-21-openjdk flutter build apk --release
adb -s 23181JEGR08034 install -r build/app/outputs/flutter-apk/app-release.apk
adb -s 23181JEGR08034 shell am start -n com.kuhy.focus_owner/.MainActivity
```

`JAVA_HOME` is required: the system default JDK 26 breaks the Android Gradle
plugin's `jlink` transform.

Release build only — device owner refuses a debuggable one. Then tap **Run
enforcement now** and read the status card; `EnforcementService` is not
exported, so it cannot be started from adb.

> **Never** `adb uninstall`, `pm clear`, or wipe this app's data. Uninstalling a
> device owner strands ownership with no holder and a factory reset becomes the
> only exit. `install -r` is safe and preserves the home location.

## Why the escape hatch ships first

`dpm remove-active-admin` does not work on a device owner. The only exit that
avoids a factory reset is `DevicePolicyManager.clearDeviceOwnerApp()`, callable
solely by this package on itself. So `releaseDeviceOwner()` is implemented,
unit-tested, and reachable from the main screen with no PC attached.

Accounts now exist on the device, so `dpm set-device-owner` would refuse to run
again: releasing is a one-way door until a wipe. The confirmation dialog says so
in those terms. See
`~/.claude/projects/-home-kuhy-testsAndMisc/memory/device-owner-not-root-banking-works.md`.

## Known gap

The network layer does not filter `youtube.com`. `private_dns_host` is empty
(the router does not forward 853, and under VPN lockdown app DNS goes to the
VPN's own resolver anyway), and RethinkDNS's blocklists can be switched off from
inside that app. So a browser reaches YouTube on the web **when away from home**.
At home and during curfew every browser is hidden, which is what closes it there.
