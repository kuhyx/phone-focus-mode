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

## Redoing this after a factory reset

The purge is per-user state and does not survive a wipe. Re-run
`./distraction_purge.sh` after re-enrolling the device.
