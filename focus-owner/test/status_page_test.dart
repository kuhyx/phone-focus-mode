// StatusPage widget behaviour.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/device_policy.dart';
import 'package:focus_owner/main.dart';
import 'package:focus_owner/policy.dart';
import 'package:focus_owner/theme.dart';

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

/// An [Icon] whose spoken label contains [text].
Finder _spoken(String text) => find.byWidgetPredicate(
  (w) => w is Icon && (w.semanticLabel ?? '').contains(text),
);

/// The value glyph of the status row with [key] (its last icon).
Icon _rowIcon(WidgetTester tester, String key) => tester.widget<Icon>(
  find.descendant(of: find.byKey(Key(key)), matching: find.byType(Icon)).last,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StatusPage', () {
    testWidgets('hides the release button when not device owner', (
      tester,
    ) async {
      final fake = _fakeChannel({'status': _statusMap()});
      await tester.pumpWidget(
        MaterialApp(
          home: StatusPage(
            policy: DevicePolicy(fake.channel),
            loadFocusPolicy: _stubPolicy,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('release-owner')), findsNothing);
      // "Nothing is enforced" is the owner row's danger-coloured cross.
      final owner = _rowIcon(tester, 'row-owner');
      expect(owner.icon, Icons.cancel);
      expect(owner.color, kDanger);
    });

    testWidgets('shows the release button when device owner', (tester) async {
      final fake = _fakeChannel({'status': _statusMap(isDeviceOwner: true)});
      await tester.pumpWidget(
        MaterialApp(
          home: StatusPage(
            policy: DevicePolicy(fake.channel),
            loadFocusPolicy: _stubPolicy,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('release-owner')), findsOneWidget);
      // The old "none (inert build)" label was a leftover from before this app
      // enforced anything, and it stayed on screen for weeks while YouTube was
      // in fact being hidden. With no pass recorded the honest answer is that
      // nothing is known yet, not that nothing is applied.
      // That row now lives in the details sheet, one tap away.
      expect(_spoken('no pass recorded yet'), findsNothing);
      await tester.tap(find.byIcon(Icons.expand_less));
      await tester.pumpAndSettle();
      expect(_spoken('no pass recorded yet'), findsOneWidget);
      expect(find.byKey(const Key('detail-package')), findsOneWidget);
      expect(find.byKey(const Key('detail-allowed-apps')), findsOneWidget);
      expect(find.byKey(const Key('detail-workout-domains')), findsOneWidget);
    });

    testWidgets('reports when no home is set, since that means everywhere', (
      tester,
    ) async {
      // Without coordinates every pass decides LOCATION_UNKNOWN and fails
      // closed, so enforcement is permanent rather than geofenced. That is a
      // large behavioural difference and must be visible on screen.
      final fake = _fakeChannel({
        'status': _statusMap(isDeviceOwner: true),
        'hasHomeLocation': false,
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

      final fence = _rowIcon(tester, 'row-geofence');
      expect(fence.icon, Icons.cancel);
      expect(fence.color, kDanger);
      expect(fence.semanticLabel, contains('enforcing everywhere'));
      expect(_spoken('Set home to current location'), findsOneWidget);
      expect(find.byIcon(Icons.add_home), findsOneWidget);
    });

    testWidgets('offers to update home once one is set', (tester) async {
      final fake = _fakeChannel({
        'status': _statusMap(isDeviceOwner: true),
        'hasHomeLocation': true,
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

      final fence = _rowIcon(tester, 'row-geofence');
      expect(fence.icon, Icons.check_circle);
      expect(fence.color, kAccent);
      expect(_spoken('Update home to here'), findsOneWidget);
      expect(find.byIcon(Icons.edit_location_alt), findsOneWidget);
    });

    testWidgets('release is confirmed before it runs', (tester) async {
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

      await tester.scrollUntilVisible(
        find.byKey(const Key('release-owner')),
        100,
      );
      await tester.tap(find.byKey(const Key('release-owner')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('release-dialog')), findsOneWidget);

      // Cancelling must not call through to the platform.
      await tester.tap(find.byKey(const Key('release-cancel')));
      await tester.pumpAndSettle();
      expect(
        fake.calls.where((c) => c.method == 'releaseDeviceOwner'),
        isEmpty,
      );
    });
  });
}

/// One JSON-lines record, as the platform channel returns them.
