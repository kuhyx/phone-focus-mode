import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/debug_log_page.dart';
import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/enforcement_status_card.dart';
import 'package:focus_owner/theme.dart';

EnforcementRecord _record({
  String reason = 'AT_HOME',
  Object? distanceM = 42.0,
  Object? fixAccuracyM = 12.0,
  Object? curfewActive = false,
  Object? homeConfigured = true,
  Object? failure,
  int hidDelta = 0,
  int tsOffsetMinutes = 0,
  List<Object?> hidden = const [
    {'pkg': 'com.google.android.youtube', 'why': 'ALWAYS_BLOCKED'},
  ],
}) => EnforcementRecord.fromJson({
  'ts': DateTime.now()
      .subtract(Duration(minutes: tsOffsetMinutes))
      .millisecondsSinceEpoch,
  'reason': reason,
  'distance_m': distanceM,
  'threshold_m': 180.0,
  'inside_fence': true,
  'home_configured': homeConfigured,
  'fix': {
    'age_ms': 45000,
    'provider': 'gps',
    'accuracy_m': fixAccuracyM,
    'outcome': 'ACTIVE_OK',
  },
  'curfew_active': curfewActive,
  'curfew_window': '23:00-05:00',
  'counts': {
    'to_hide': 3,
    'to_show': 58,
    'hid_delta': hidDelta,
    'restored_delta': 0,
  },
  'hidden': hidden,
  'failure': failure,
});

Future<void> _pump(WidgetTester tester, EnforcementRecord? record) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: EnforcementStatusCard(record: record, onOpenLog: () {}),
          ),
        ),
      ),
    );

/// An [Icon] drawn with [icon], optionally in [color].
Finder _icon(IconData icon, {Color? color}) => find.byWidgetPredicate(
  (w) => w is Icon && w.icon == icon && (color == null || w.color == color),
);

/// An [Icon] whose spoken label contains [text].
Finder _spoken(String text) => find.byWidgetPredicate(
  (w) => w is Icon && (w.semanticLabel ?? '').contains(text),
);

/// The card's big state glyph.
Icon _state(WidgetTester tester) => tester.widget<Icon>(
  find.descendant(
    of: find.byKey(const Key('card-state')),
    matching: find.byType(Icon),
  ),
);

/// Text inside the row with [key].
Finder _inRow(String key, String text) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.text(text));

void main() {
  group('EnforcementStatusCard', () {
    testWidgets('shows an empty hourglass when no pass has run yet', (
      tester,
    ) async {
      await _pump(tester, null);
      expect(find.byKey(const Key('card-empty')), findsOneWidget);
    });

    testWidgets('shows the reason, distance and curfew state', (tester) async {
      await _pump(tester, _record());
      expect(_state(tester).icon, Icons.home);
      expect(_state(tester).color, kAccent);
      expect(_inRow('row-distance', '42 m'), findsOneWidget);
      expect(_inRow('row-distance', '180 m'), findsOneWidget);
      expect(_icon(Icons.toggle_off, color: kMuted), findsOneWidget);
      expect(_inRow('row-curfew', '23:00-05:00'), findsOneWidget);
      expect(_inRow('row-apps', '3'), findsOneWidget);
      expect(_inRow('row-apps', '58'), findsOneWidget);
    });

    testWidgets('LOCATION_UNKNOWN is distinguishable from AT_HOME', (
      tester,
    ) async {
      // The core of the bug being fixed: these two apply the identical sweep,
      // so without this the phone gives no way to tell them apart.
      await _pump(tester, _record(reason: 'LOCATION_UNKNOWN', distanceM: null));
      expect(_state(tester).icon, Icons.location_disabled);
      expect(_state(tester).color, kDanger);
      expect(_state(tester).semanticLabel, contains('as if you were at home'));
      expect(_spoken('unknown - no location fix'), findsOneWidget);
    });

    testWidgets('a missing home is called out rather than shown as AT_HOME', (
      tester,
    ) async {
      await _pump(tester, _record(homeConfigured: false));
      expect(_state(tester).icon, Icons.add_home);
      expect(_state(tester).color, kDanger);
      expect(_spoken('no home set'), findsOneWidget);
    });

    testWidgets('a failed pass reports the failure', (tester) async {
      await _pump(tester, _record(failure: 'policy unreadable'));
      expect(_state(tester).icon, Icons.error);
      expect(_state(tester).semanticLabel, contains('policy unreadable'));
      expect(find.textContaining('policy unreadable'), findsNothing);
    });

    testWidgets('an implausibly vague fix is flagged', (tester) async {
      await _pump(tester, _record(fixAccuracyM: 1400.0));
      expect(_icon(Icons.blur_on, color: kWarn), findsOneWidget);
      final accuracy = tester.widget<Text>(find.text('±1400 m'));
      expect(accuracy.style?.color, kDanger);
    });

    testWidgets('a precise fix is not flagged', (tester) async {
      await _pump(tester, _record());
      expect(_icon(Icons.blur_on), findsNothing);
      expect(_icon(Icons.satellite_alt), findsOneWidget);
      expect(find.text('45 s'), findsOneWidget);
    });

    testWidgets('curfew renders as active when it is', (tester) async {
      await _pump(tester, _record(reason: 'CURFEW', curfewActive: true));
      expect(_state(tester).icon, Icons.bedtime);
      expect(_icon(Icons.toggle_on, color: kWarn), findsOneWidget);
    });

    testWidgets('a stalled schedule is called out', (tester) async {
      await _pump(tester, _record(tsOffsetMinutes: 90));
      expect(find.byKey(const Key('age-stale')), findsOneWidget);
      expect(_icon(Icons.timer_off, color: kDanger), findsOneWidget);
    });

    testWidgets('a fresh pass shows its age, not a stall', (tester) async {
      await _pump(tester, _record(tsOffsetMinutes: 5));
      expect(find.byKey(const Key('age')), findsOneWidget);
      expect(find.text('5 min'), findsOneWidget);
    });

    testWidgets('changes made this pass are shown when non-zero', (
      tester,
    ) async {
      await _pump(tester, _record());
      expect(_icon(Icons.remove_circle_outline), findsNothing);
      await _pump(tester, _record(hidDelta: 2));
      expect(_icon(Icons.remove_circle_outline), findsOneWidget);
      expect(_inRow('row-apps', '2'), findsOneWidget);
    });

    testWidgets('each hidden app can be opened to show why', (tester) async {
      await _pump(tester, _record());
      await tester.tap(find.byKey(const Key('hidden-list')));
      await tester.pumpAndSettle();
      expect(find.text('com.google.android.youtube'), findsOneWidget);
      expect(_icon(Icons.block, color: kDanger), findsOneWidget);
      expect(_spoken('always blocked, everywhere'), findsOneWidget);
    });

    testWidgets('no hidden apps means no expander', (tester) async {
      await _pump(tester, _record(hidden: const []));
      expect(find.byKey(const Key('hidden-list')), findsNothing);
    });

    testWidgets('never renders anything that looks like a coordinate', (
      tester,
    ) async {
      // The record carries no latitude/longitude by design; this pins that the
      // screen cannot start showing one.
      await _pump(tester, _record());
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join(' ');
      expect(RegExp(r'\d{1,3}\.\d{4,}').hasMatch(texts), isFalse);
    });

    testWidgets('the log button is reachable', (tester) async {
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EnforcementStatusCard(
                record: _record(),
                onOpenLog: () => opened = true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('row-debug')));
      expect(opened, isTrue);
    });

    testWidgets('the location rows re-acquire a fix only when wired', (
      tester,
    ) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EnforcementStatusCard(
              record: _record(),
              onOpenLog: () {},
              onRefreshLocation: () => tapped++,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('row-fix')));
      await tester.tap(find.byKey(const Key('row-distance')));
      expect(tapped, 2);

      // Without the callback the rows are plain. Buttons elsewhere on the
      // card own InkWells, so only the row's own ancestors count.
      await _pump(tester, _record());
      final rowInk = find.descendant(
        of: find.byKey(const Key('row-fix')),
        matching: find.byType(InkWell),
      );
      expect(rowInk, findsNothing);
    });
  });

  group('DebugLogPage', () {
    testWidgets('shows an empty hourglass when empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: DebugLogPage(records: [])),
      );
      expect(find.byKey(const Key('log-empty')), findsOneWidget);
    });

    testWidgets('lists passes newest first and expands one', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DebugLogPage(
            records: [
              _record(reason: 'AWAY', distanceM: 10400.0),
              _record(),
            ],
          ),
        ),
      );
      final tiles = find.byType(ExpansionTile);
      expect(
        find.descendant(
          of: tiles.first,
          matching: _icon(Icons.directions_walk),
        ),
        findsOneWidget,
      );
      expect(find.text('10.4 km'), findsOneWidget);

      await tester.tap(_icon(Icons.directions_walk));
      await tester.pumpAndSettle();
      expect(_icon(Icons.gps_fixed), findsOneWidget);
      expect(find.byKey(const Key('log-copy')), findsOneWidget);
    });

    testWidgets('a failed pass is marked in the list', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DebugLogPage(records: [_record(failure: 'policy unreadable')]),
        ),
      );
      expect(_icon(Icons.error, color: kDanger), findsOneWidget);
      await tester.tap(_icon(Icons.error, color: kDanger));
      await tester.pumpAndSettle();
      expect(_spoken('Failure: policy unreadable'), findsOneWidget);
    });

    testWidgets('copying a record does not throw', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: DebugLogPage(records: [_record()])),
      );
      await tester.tap(_icon(Icons.home, color: kAccent));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('log-copy')));
      await tester.pumpAndSettle();
    });
  });
}
