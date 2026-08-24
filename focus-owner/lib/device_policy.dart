import 'package:flutter/services.dart';

/// Provisioning state reported by the native side.
class DevicePolicyStatus {
  const DevicePolicyStatus({
    required this.packageName,
    required this.isDeviceOwner,
    required this.isAdminActive,
    required this.sdkInt,
    required this.restrictionsApplied,
    this.hasAccounts = true,
  });

  /// Builds a status from the raw platform-channel map.
  factory DevicePolicyStatus.fromMap(Map<Object?, Object?> map) {
    return DevicePolicyStatus(
      packageName: map['packageName']! as String,
      isDeviceOwner: map['isDeviceOwner']! as bool,
      isAdminActive: map['isAdminActive']! as bool,
      sdkInt: map['sdkInt']! as int,
      restrictionsApplied: map['restrictionsApplied']! as bool,
      // Absent from an older native side; default to the scarier reading.
      hasAccounts: map['hasAccounts'] as bool? ?? true,
    );
  }

  final String packageName;
  final bool isDeviceOwner;
  final bool isAdminActive;
  final int sdkInt;

  /// Whether any user restriction is currently enforced.
  ///
  /// Hardcoded false by the native side and NOT a statement about enforcement
  /// — the app is live and hiding packages, and it does apply user
  /// restrictions (`DISALLOW_CONFIG_VPN`, `DISALLOW_CONFIG_PRIVATE_DNS`) once
  /// those layers are locked. Nothing reads this back from the system yet, so
  /// treat it as "not reported" rather than "nothing applied"; the honest
  /// enforcement state is the hidden-app count in the latest
  /// [EnforcementRecord], which is what the status screen shows.
  final bool restrictionsApplied;

  /// Whether any account exists, which decides if releasing is reversible.
  ///
  /// `dpm set-device-owner` refuses while accounts exist, so once one is
  /// added, releasing can only be undone by a factory reset.
  final bool hasAccounts;
}

/// Dart side of the device-policy platform channel.
class DevicePolicy {
  const DevicePolicy([this.channel = _defaultChannel]);

  static const MethodChannel _defaultChannel =
      MethodChannel('com.kuhy.focus_owner/device_policy');

  final MethodChannel channel;

  /// Reads the current provisioning state.
  Future<DevicePolicyStatus> status() async {
    final result =
        await channel.invokeMethod<Map<Object?, Object?>>('status');
    return DevicePolicyStatus.fromMap(result!);
  }

  /// Runs one enforcement pass now and arms the schedule.
  ///
  /// The service schedules the following run at the end of each pass, so this
  /// is also how the chain is started on a device that has not rebooted since
  /// the app was installed.
  Future<bool> runEnforcementNow() async =>
      await channel.invokeMethod<bool>('runEnforcementNow') ?? false;

  /// Cancels any pending scheduled evaluation.
  Future<bool> cancelEnforcement() async =>
      await channel.invokeMethod<bool>('cancelEnforcement') ?? false;

  /// Reads the durable enforcement log, newest first.
  ///
  /// This is the only way to see what the enforcer has been doing: logcat
  /// rotates (measured empty while 82 alarms had fired) and `run-as` is
  /// refused on the release build device owner requires, so neither adb route
  /// works. Returns raw JSON lines for [EnforcementRecord.parseLines].
  Future<List<String>> readEnforcementLog({int limit = 200}) async {
    final lines = await channel.invokeMethod<List<Object?>>(
      'readEnforcementLog',
      {'limit': limit},
    );
    return lines?.whereType<String>().toList() ?? const [];
  }

  /// Relinquishes device ownership without wiping the device.
  ///
  /// This is the escape hatch. It is deliberately reachable from the app's
  /// main screen with no PC attached, because the situation it exists for is
  /// one where ADB may already be disallowed.
  Future<bool> releaseDeviceOwner() async {
    final released = await channel.invokeMethod<bool>('releaseDeviceOwner');
    return released ?? false;
  }

  /// Records the current location as home, enabling the geofence.
  ///
  /// Returns null on success, or a message explaining the failure. Lives in
  /// the app rather than a script because `run-as` does not work on the
  /// release build that device owner requires.
  Future<String?> setHomeToCurrentLocation() async =>
      channel.invokeMethod<String>('setHomeToCurrentLocation');

  /// Whether home coordinates are provisioned.
  ///
  /// Without them every pass decides LOCATION_UNKNOWN and fails closed, so
  /// enforcement applies everywhere rather than only at home.
  Future<bool> hasHomeLocation() async =>
      await channel.invokeMethod<bool>('hasHomeLocation') ?? false;

  /// Prevents the user from turning the always-on VPN off in Settings.
  ///
  /// Applied only after the VPN filter is confirmed working: pinning it over
  /// a broken configuration would lock the broken state in.
  Future<bool> setVpnConfigBlocked({required bool blocked}) async =>
      await channel.invokeMethod<bool>(
        'setVpnConfigBlocked',
        {'blocked': blocked},
      ) ??
      false;
}
