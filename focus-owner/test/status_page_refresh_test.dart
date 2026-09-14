// StatusPage refresh: the icon and the location rows re-acquire a fix.

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
  const channel = MethodChannel('test/device_policy_refresh');
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (!responses.containsKey(call.method)) {
          throw PlatformException(code: 'unimplemented', message: 'no stub');
        }
        return responses[call.method];
      });
  return (channel: channel, calls: calls);
}

Map<String, Object?> _statusMap() => {
  'packageName': 'com.kuhy.focus_owner',
  'isDeviceOwner': true,
  'isAdminActive': true,
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

/// One JSON-lines record, as the platform channel returns them.
String _logLine() => jsonEncode({
  'ts': DateTime.now().millisecondsSinceEpoch,
  'reason': 'AT_HOME',
  'distance_m': 0.0,
  'threshold_m': 150.0,
  'inside_fence': true,
  'home_configured': true,
  'fix': {
    'age_ms': 5000,
    'provider': 'gps',
    'accuracy_m': 11.0,
    'outcome': 'ACTIVE_OK',
  },
  'curfew_active': false,
  'curfew_window': '23:00-05:00',
  'counts': {'to_hide': 3, 'to_show': 58, 'hid_delta': 0, 'restored_delta': 0},
  'hidden': const <Object?>[],
  'failure': null,
});

/// Stubs every method the refresh path touches. The log line is static, so
/// every poll sees the same timestamp and the pass "times out" after ~30 s.
({MethodChannel channel, List<MethodCall> calls}) _refreshChannel({
  bool canRun = true,
}) => _fakeChannel({
  'status': _statusMap(),
  'hasHomeLocation': true,
  if (canRun) 'runEnforcementNow': true,
  'readEnforcementLog': [_logLine()],
});

Future<void> _pumpPage(WidgetTester tester, MethodChannel channel) async {
  await tester.pumpWidget(
    MaterialApp(
      home: StatusPage(
        policy: DevicePolicy(channel),
        loadFocusPolicy: _stubPolicy,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Iterable<MethodCall> _runs(List<MethodCall> calls) =>
    calls.where((c) => c.method == 'runEnforcementNow');

/// Past the polling budget (~30 s), then settled.
Future<void> _finishPass(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 40));
  await tester.pumpAndSettle();
}

void main() {
  group('StatusPage refresh', () {
    testWidgets('the icon runs a fresh-fix pass and shows a spinner', (
      tester,
    ) async {
      final fake = _refreshChannel();
      await _pumpPage(tester, fake.channel);
      // Loading the page re-reads state; it must not run a pass by itself.
      expect(_runs(fake.calls), isEmpty);

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);

      await _finishPass(tester);
      final runs = _runs(fake.calls).toList();
      expect(runs, hasLength(1));
      expect(runs.single.arguments, {'freshFix': true});
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.text('Location refresh finished'), findsOneWidget);
    });

    for (final row in ['Location fix', 'Distance from home']) {
      testWidgets('tapping "$row" runs a fresh-fix pass', (tester) async {
        final fake = _refreshChannel();
        await _pumpPage(tester, fake.channel);

        await tester.tap(find.text(row));
        await _finishPass(tester);

        final runs = _runs(fake.calls).toList();
        expect(runs, hasLength(1));
        expect(runs.single.arguments, {'freshFix': true});
      });
    }

    testWidgets('"Run enforcement now" keeps the cache window', (tester) async {
      final fake = _refreshChannel();
      await _pumpPage(tester, fake.channel);

      await tester.scrollUntilVisible(find.text('Run enforcement now'), 100);
      await tester.tap(find.text('Run enforcement now'));
      await _finishPass(tester);

      expect(_runs(fake.calls).single.arguments, {'freshFix': false});
      expect(find.text('Enforcement run finished'), findsOneWidget);
    });

    testWidgets('the rows and the icon are inert while a pass runs', (
      tester,
    ) async {
      final fake = _refreshChannel();
      await _pumpPage(tester, fake.channel);

      await tester.tap(find.text('Location fix'));
      await tester.pump();
      await tester.tap(find.text('Distance from home'));
      expect(find.byTooltip('Refresh'), findsNothing);
      await _finishPass(tester);

      expect(_runs(fake.calls), hasLength(1));
    });

    testWidgets('a channel failure does not leave the page stuck busy', (
      tester,
    ) async {
      final fake = _refreshChannel(canRun: false);
      await _pumpPage(tester, fake.channel);

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();

      expect(find.text('Could not start enforcement'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });
  });
}
