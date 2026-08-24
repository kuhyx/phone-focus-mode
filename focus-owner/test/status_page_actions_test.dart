// StatusPage release, enforcement and polling behaviour.

// StatusPage widget behaviour.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/device_policy.dart';
import 'package:focus_owner/main.dart';
import 'package:focus_owner/policy.dart';

/// Builds a channel whose handler answers from [responses], recording calls.
({MethodChannel channel, List<MethodCall> calls}) _fakeChannel(
  Map<String, Object?> responses,
) {
  const channel = MethodChannel('test/device_policy');
  final calls = <MethodCall>[];
  // hasHomeLocation is read on every status refresh, so it is defaulted here
  // rather than restated in each widget test. An explicit stub still wins,
  // which is what the geofence-state tests rely on.
  final stubs = {'hasHomeLocation': false, ...responses};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    if (!stubs.containsKey(call.method)) {
      throw PlatformException(code: 'unimplemented', message: 'no stub');
    }
    return stubs[call.method];
  });
  return (channel: channel, calls: calls);
}

Map<String, Object?> _statusMap({bool isDeviceOwner = false}) => {
      'packageName': 'com.kuhy.focus_owner',
      'isDeviceOwner': isDeviceOwner,
      'isAdminActive': isDeviceOwner,
      'sdkInt': 36,
      'restrictionsApplied': false,
    };

/// Minimal policy so widget tests never touch the (empty) test rootBundle.
Future<FocusPolicy> _stubPolicy() async => FocusPolicy.fromJson({
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StatusPage actions', () {
    testWidgets('confirming release calls the platform', (tester) async {
      final fake = _fakeChannel({
        'status': _statusMap(isDeviceOwner: true),
        'releaseDeviceOwner': true,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: StatusPage(
            policy: DevicePolicy(fake.channel),
            loadFocusPolicy: _stubPolicy,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Release device owner'), 100);
      await tester.tap(find.text('Release device owner'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Release'));
      await tester.pumpAndSettle();

      expect(
        fake.calls.where((c) => c.method == 'releaseDeviceOwner'),
        hasLength(1),
      );
      expect(find.text('Device owner released'), findsOneWidget);
    });

    testWidgets('running enforcement waits for the new record', (tester) async {
      // The pass runs in a separate service process and now waits for a
      // location fix, so re-reading immediately returns the PREVIOUS record.
      // Measured: after re-anchoring home the card still showed the old
      // distance, which reads as "the button did nothing".
      var passRan = false;
      const channel = MethodChannel('test/refresh');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'status':
            return _statusMap(isDeviceOwner: true);
          case 'hasHomeLocation':
            return true;
          case 'runEnforcementNow':
            passRan = true;
            return true;
          case 'readEnforcementLog':
            return [_logLine(passRan ? 'AT_HOME' : 'AWAY')];
          default:
            throw PlatformException(code: 'unimplemented');
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          home: StatusPage(
            policy: DevicePolicy(channel),
            loadFocusPolicy: _stubPolicy,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('AWAY'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('Run enforcement now'), 100);
      await tester.tap(find.text('Run enforcement now'));
      // Long enough for at least one poll interval to elapse.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text('AT HOME'), findsOneWidget);
      expect(find.text('AWAY'), findsNothing);
    });

    testWidgets('a stuck pass stops polling instead of hanging',
        (tester) async {
      // If no new record ever lands the UI must still settle, not spin.
      const channel = MethodChannel('test/stuck');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'status':
            return _statusMap(isDeviceOwner: true);
          case 'hasHomeLocation':
            return true;
          case 'runEnforcementNow':
            return true;
          case 'readEnforcementLog':
            return [_logLine('AWAY')];
          default:
            throw PlatformException(code: 'unimplemented');
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          home: StatusPage(
            policy: DevicePolicy(channel),
            loadFocusPolicy: _stubPolicy,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Run enforcement now'), 100);
      await tester.tap(find.text('Run enforcement now'));
      // Past the polling budget (~30 s).
      await tester.pump(const Duration(seconds: 40));
      await tester.pumpAndSettle();

      expect(find.text('AWAY'), findsOneWidget);
    });
  });
}



/// One JSON-lines record, as the platform channel returns them.
String _logLine(String reason) => jsonEncode({
      'ts': DateTime.now().millisecondsSinceEpoch,
      'reason': reason,
      'distance_m': reason == 'AWAY' ? 766.0 : 0.0,
      'threshold_m': 150.0,
      'inside_fence': reason != 'AWAY',
      'home_configured': true,
      'fix': {
        'age_ms': 5000,
        'provider': 'gps',
        'accuracy_m': 11.0,
        'outcome': 'ACTIVE_OK',
      },
      'curfew_active': false,
      'curfew_window': '23:00-05:00',
      'counts': {
        'to_hide': 3,
        'to_show': 58,
        'hid_delta': 0,
        'restored_delta': 0,
      },
      'hidden': const <Object?>[],
      'failure': null,
    });
