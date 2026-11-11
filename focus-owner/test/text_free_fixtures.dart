// Fixtures for text_free_test.dart: one log record, the fake platform
// channel, device status and policy. A part so they stay library-private.

part of 'text_free_test.dart';

/// One JSON-lines record that exercises every row and hide reason.
String _record({
  String reason = 'AT_HOME',
  String? failure,
  bool? homeConfigured = true,
  double? accuracy = 12,
  int ageMinutes = 0,
  bool withHidden = true,
}) => jsonEncode({
  'ts': DateTime.now()
      .subtract(Duration(minutes: ageMinutes))
      .millisecondsSinceEpoch,
  'reason': reason,
  'distance_m': 1766.0,
  'threshold_m': 150.0,
  'inside_fence': false,
  'home_configured': homeConfigured,
  'fix': {
    'age_ms': 75000,
    'provider': 'gps',
    'accuracy_m': accuracy,
    'outcome': 'TIMEOUT',
  },
  'curfew_active': true,
  'curfew_window': '23:00-05:00',
  'counts': {'to_hide': 3, 'to_show': 40, 'hid_delta': 1, 'restored_delta': 2},
  'hidden': withHidden
      ? [
          {'pkg': 'com.bad.app', 'why': 'ALWAYS_BLOCKED'},
          {'pkg': 'com.day.app', 'why': 'NOT_IN_ALLOWLIST'},
          {'pkg': 'com.night.app', 'why': 'NOT_IN_NIGHT_ALLOWLIST'},
          {'pkg': 'com.lock.app', 'why': 'NOT_IN_LOCKDOWN_ALLOWLIST'},
          {'pkg': 'com.odd.app', 'why': 'SOMETHING_NEW'},
        ]
      : <Object>[],
  'failure': ?failure,
});

/// A channel answering from [stubs]; anything else throws, like a failure.
MethodChannel _channel(Map<String, Object?> stubs) {
  const channel = MethodChannel('test/text_free');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        if (!stubs.containsKey(call.method)) {
          throw PlatformException(code: 'x', message: 'no stub for this call');
        }
        return stubs[call.method];
      });
  return channel;
}

Map<String, Object?> _status({required bool owner}) => {
  'packageName': 'com.kuhy.focus_owner',
  'isDeviceOwner': owner,
  'isAdminActive': owner,
  'sdkInt': 36,
  'restrictionsApplied': false,
};

Future<FocusPolicy> _policy() async => FocusPolicy.fromJson({
  'schema_version': kSupportedSchemaVersion,
  'home': {
    'latitude': null,
    'longitude': null,
    'radius_m': 150.0,
    'hysteresis_m': 30.0,
  },
  'curfew': {'start': '23:00', 'end': '05:00'},
  'launcher_package': 'com.launcher',
  'allowed_packages': ['com.good'],
  'night_allowed_packages': <String>[],
  'never_disable_prefixes': <String>[],
  'workout_unblock_domains': ['youtube.com'],
  'browser_packages': <String>[],
});

Future<FocusPolicy> _brokenPolicy() async =>
    throw const PolicyFormatException('schema mismatch in asset');
