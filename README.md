# focus_owner

Device Owner companion app for unrooted focus mode. **Currently inert**: it can
be provisioned as device owner, but it applies no restrictions.

## Why the escape hatch ships first

`dpm remove-active-admin` does not work on a device owner. The only exit that
avoids a factory reset is `DevicePolicyManager.clearDeviceOwnerApp()`, callable
solely by this package on itself. An app that locks the device down before
proving it can let go leaves a soft-brick recoverable only through fastboot —
painful on a locked bootloader, and impossible to reach if
`DISALLOW_FACTORY_RESET` is ever set.

So: `DevicePolicyBridge.releaseDeviceOwner()` is implemented, unit-tested, and
reachable from the app's main screen with no PC attached. Enforcement is added
only after that path has been exercised on a provisioned device.

## Provisioning (NOT done yet — requires a factory reset)

`dpm set-device-owner` refuses to run while any account exists on the device.
The Pixel 6a has 6, so provisioning means a wipe. See
`~/.claude/projects/-home-kuhy-testsAndMisc/memory/device-owner-not-root-banking-works.md`
for what does and does not survive that, and for the Google Wallet open risk.

Once wiped, before adding any account:

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell dpm set-device-owner com.kuhy.focus_owner/.FocusDeviceAdminReceiver
```

Then immediately verify tap-to-pay and banking apps, while the release button
is still reachable.

## Build and verify

```bash
cd ~/testsAndMisc/focus_owner
flutter analyze && flutter test
flutter build apk --debug
adb -s 23181JEGR08034 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s 23181JEGR08034 shell am start -n com.kuhy.focus_owner/.MainActivity
```

The status screen reads live state over the platform channel; "Android SDK 36"
confirms the Kotlin bridge is working.

## Still to do

- Consume the policy JSON from `python_pkg/focus_policy` (`export.py`).
- Add enforcement (`setApplicationHidden`, `addUserRestriction`,
  `setAlwaysOnVpnPackage`) — only after the release path is verified on-device.
- Verify `setApplicationHidden` survives a reboot. `pm suspend` and
  `pm disable-user` both do NOT; do not assume the DPM equivalent behaves the
  same until measured.
