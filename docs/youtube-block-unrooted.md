# Blocking YouTube on an unrooted Pixel 6a

Applied and verified 2026-08-09 on `23181JEGR08034` (Android 16, SDK 36).
No root, no Device Owner, no factory reset.

## What actually works: `pm uninstall --user 0`

Unregisters a package for one user while leaving the APK on the read-only
system image.

| Mechanism | Survives reboot? |
| --- | --- |
| `pm suspend` | No — measured |
| `pm disable-user` | No — measured |
| `dpm setApplicationHidden` | Yes — but needs Device Owner, i.e. a wipe |
| **`pm uninstall --user 0`** | **Yes — measured, twice** |

Reversible with `pm install-existing --user 0 <pkg>`: no download, no data
loss, because the APK never left the device.

## Why focus_owner cannot do this job

`EnforcementRunner.installedThirdPartyPackages()` filters to packages without
`FLAG_SYSTEM`. YouTube ships at `/product/app/YouTube` **with** `FLAG_SYSTEM`,
so the Device Owner sweep would skip it — even after the factory reset. The
apps most worth blocking are preinstalled, which is exactly the set that sweep
excludes. Worth fixing there separately; it does not block anything today.

## Current state

Removed for user 0, all reboot-verified:

- `com.google.android.youtube`
- `com.google.android.apps.youtube.music`
- `com.android.chrome`

Driven by `phone_focus_mode/distraction_purge.sh` (`--list`, `--status`,
`--restore`). It re-checks each package with `dumpsys` after acting rather
than trusting the `pm` exit code, and exits non-zero if anything is still
installed — so a Play Store reinstall surfaces as a failure instead of a
silent no-op.

## Layer 2: uBlock Origin in Firefox

Independent of the VPN, and that is the point: stopping RethinkDNS does
**not** restore YouTube in Firefox. Verified by force-stopping
`com.celzero.bravedns` and loading youtube.com, which produced *"uBlock
Origin has prevented the following page from loading — `||youtube.com^` —
found in: My filters"*.

The filters, in uBlock's dashboard → **My filters**:

```
! YouTube block
||youtube.com^
||youtu.be^
||googlevideo.com^
||ytimg.com^
||youtube-nocookie.com^
||ggpht.com^
||yt3.ggpht.com^
||m.youtube.com^
```

Add them by writing that list to a file, pushing it to
`/sdcard/Download/`, triggering a media scan (`am broadcast -a
android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/...`,
or the picker will not see it), then using uBlock's **import** button.
Do NOT type them with `adb shell input text`: it silently strips `|` and
`^`, leaving bare domains that do not block. Press the checkmark to
apply, and confirm it greys out.

These live in the Firefox profile, so they are **not** captured by
`phone_backup.sh` and must be re-added by hand after a wipe.

The block page has a **Proceed** button — one tap. This layer raises the
cost of bypassing; it does not remove the bypass.

## What is NOT blocked

**Firefox (`org.mozilla.fenix`) is still installed and still reaches
youtube.com.** It is the only remaining browser after Chrome's removal.

Unlike the three packages above, Firefox is user-installed
(`/data/app/...`, no `FLAG_SYSTEM`), so `pm uninstall --user 0` would
**permanently delete it and its data** — no `install-existing` recovery, a
full reinstall from the Play Store. That asymmetry is why it was left alone
rather than swept up with the rest. Decide deliberately.

`com.google.android.webview` was checked and left in place: it is the system
WebView provider, so removing it would break in-app browsers everywhere.
Chrome and WebView are separate packages on this device, which is why
removing Chrome is safe.

## The web path, and why DNS is parked

Removing the app kills the recommendation feed, notifications and the
account-linked session — most of the pull. It does not stop typing
`youtube.com` into a browser.

Previously rejected approaches, from `focus_owner/docs/`:

- **Home-hosted DoT resolver.** Android's Private DNS fails *closed*, so PC
  off = phone has no internet at all. Rejected: the phone must work with the
  PC off.
- **Hosted DNS (NextDNS, AdGuard, ControlD).** No provider ingests the 185k
  domain blocklist; free tiers fail *open* past ~300k queries/month.

The remaining candidate is a **local-VPN content blocker** — an on-device
`VpnService` that filters without any network dependency, so it works with the
PC off and does not fail closed on network loss. Not yet scoped; the VPN slot
was going to be checked when the device disconnected. Note Android allows only
one active VPN at a time, so this would conflict with any real VPN.

## How strong this actually is

Measured, not assumed:

| Layer | Undo cost |
| --- | --- |
| App removal | **One tap.** Google Play shows a live **Install** button for YouTube (checked on device 2026-08-09; not installed). |
| RethinkDNS rules | A few taps — the VPN toggle in Settings or the quick-settings tile. |
| uBlock filters | **Proceed** on the block page, or disabling the extension. |

Nothing here is tamper-resistant, and nothing here can be: on an
unrooted device without Device Owner, no app can prevent the user
disabling a VPN or reinstalling from Play. The layers are independent —
undoing one does not undo the others — so the cost is "three separate
places" rather than one. That is the honest ceiling.

`DISALLOW_CONFIG_VPN` plus `setAlwaysOnVpnPackage(..., lockdown)` under
Device Owner is the only tier that removes the off switch, and it needs
the factory reset in `docs/device-owner-wipe-checklist.md`. See also the
FLAG_SYSTEM note above: `focus_owner` would need fixing before Device
Owner could touch YouTube at all.

Also note nothing re-asserts the purge automatically.
`phone-auto-sync.timer` is inactive and its `ExecStart` points at a path
that does not exist, so `distraction_purge.sh` is manual today.

## Redoing this after a factory reset

The purge is per-user state and does not survive a wipe. Re-run
`./distraction_purge.sh` after re-enrolling the device.
