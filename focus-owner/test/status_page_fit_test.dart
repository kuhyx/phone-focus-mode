// StatusPage fits one phone screen: no vertical scrolling at Pixel 6a size.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/device_policy.dart';
import 'package:focus_owner/main.dart';
import 'package:focus_owner/policy.dart';

const _channel = MethodChannel('test/device_policy_fit');

String _logLine({bool busy = false}) => jsonEncode({
  'ts': DateTime.now().millisecondsSinceEpoch,
  'reason': 'AT_HOME',
  'distance_m': 12.0,
  'threshold_m': 150.0,
  'inside_fence': true,
  'home_configured': true,
  'fix': {
    'age_ms': 5000,
    'provider': 'gps',
    // A fuzzed fix adds a warning note to the card: the tallest variant.
    'accuracy_m': busy ? 3000.0 : 11.0,
    'outcome': 'ACTIVE_OK',
  },
  'curfew_active': false,
  'curfew_window': '23:00-05:00',
  'counts': {
    'to_hide': busy ? 60 : 3,
    'to_show': 58,
    'hid_delta': busy ? 2 : 0,
    'restored_delta': busy ? 1 : 0,
  },
  'hidden': [
    for (var i = 0; i < (busy ? 60 : 3); i++)
      {'pkg': 'com.example.app$i', 'why': 'ALWAYS_BLOCKED'},
  ],
  'failure': null,
});

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

Future<void> _pumpPhone(
  WidgetTester tester, {
  required bool owner,
  required bool busy,
}) async {
  tester.view
    ..physicalSize = const Size(1080, 2400)
    ..devicePixelRatio = 2.625
    ..padding = const FakeViewPadding(top: 132, bottom: 63);
  addTearDown(tester.view.reset);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        switch (call.method) {
          case 'status':
            return {
              'packageName': 'com.kuhy.focus_owner',
              'isDeviceOwner': owner,
              'isAdminActive': owner,
              'sdkInt': 36,
              'restrictionsApplied': false,
            };
          case 'hasHomeLocation':
            return true;
          case 'readEnforcementLog':
            return [_logLine(busy: busy)];
          default:
            throw PlatformException(code: 'unimplemented');
        }
      });
  await tester.pumpWidget(
    MaterialApp(
      home: StatusPage(
        policy: const DevicePolicy(_channel),
        loadFocusPolicy: _stubPolicy,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Largest scroll extent over every vertical Scrollable on screen.
double _maxVerticalExtent(WidgetTester tester) {
  var worst = 0.0;
  for (final state in tester.stateList<ScrollableState>(
    find.byType(Scrollable),
  )) {
    if (state.widget.axis == Axis.vertical) {
      worst = worst < state.position.maxScrollExtent
          ? state.position.maxScrollExtent
          : worst;
    }
  }
  return worst;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final busy in [false, true]) {
    testWidgets('fits one screen (busy card: $busy)', (tester) async {
      await _pumpPhone(tester, owner: true, busy: busy);
      expect(_maxVerticalExtent(tester), 0);
      // Above the nav bar: 63 physical px of bottom inset.
      final usableBottom = (2400 - 63) / 2.625;
      for (final key in const [
        Key('run-enforcement'),
        Key('set-home'),
        Key('lock-vpn'),
        Key('release-owner'),
      ]) {
        final finder = find.byKey(key);
        expect(finder.hitTestable(), findsOneWidget, reason: '$key');
        expect(tester.getRect(finder).bottom, lessThan(usableBottom));
      }
    });
  }

  testWidgets('non-owner state fits too', (tester) async {
    await _pumpPhone(tester, owner: false, busy: true);
    expect(_maxVerticalExtent(tester), 0);
    expect(
      find.byKey(const Key('run-enforcement')).hitTestable(),
      findsOneWidget,
    );
  });
}
