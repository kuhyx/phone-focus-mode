import 'package:flutter/services.dart';

/// Provisioning state reported by the native side.
class DevicePolicyStatus {
  const DevicePolicyStatus({
    required this.packageName,
    required this.isDeviceOwner,
    required this.isAdminActive,
    required this.sdkInt,
    required this.restrictionsApplied,
  });

  /// Builds a status from the raw platform-channel map.
  factory DevicePolicyStatus.fromMap(Map<Object?, Object?> map) {
    return DevicePolicyStatus(
      packageName: map['packageName']! as String,
      isDeviceOwner: map['isDeviceOwner']! as bool,
      isAdminActive: map['isAdminActive']! as bool,
      sdkInt: map['sdkInt']! as int,
      restrictionsApplied: map['restrictionsApplied']! as bool,
    );
  }

  final String packageName;
  final bool isDeviceOwner;
  final bool isAdminActive;
  final int sdkInt;

  /// Whether any user restriction is currently enforced.
  ///
  /// Always false in this build: the app is provisioning-capable but inert
  /// until the release path has been verified on a real device.
  final bool restrictionsApplied;
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

  /// Relinquishes device ownership without wiping the device.
  ///
  /// This is the escape hatch. It is deliberately reachable from the app's
  /// main screen with no PC attached, because the situation it exists for is
  /// one where ADB may already be disallowed.
  Future<bool> releaseDeviceOwner() async {
    final released = await channel.invokeMethod<bool>('releaseDeviceOwner');
    return released ?? false;
  }
}
