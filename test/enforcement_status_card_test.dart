import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/debug_log_page.dart';
import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/enforcement_status_card.dart';

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
}) =>
    EnforcementRecord.fromJson({
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

void main() {
  group('EnforcementStatusCard', () {
    testWidgets('says so when no pass has run yet', (tester) async {
      await _pump(tester, null);
      expect(find.textContaining('No enforcement pass recorded'), findsOneWidget);
    });

    testWidgets('shows the reason, distance and curfew state', (tester) async {
      await _pump(tester, _record());
      expect(find.text('AT HOME'), findsOneWidget);
      expect(find.text('42 m (fence 180 m)'), findsOneWidget);
      expect(find.text('inactive (23:00-05:00)'), findsOneWidget);
      expect(find.text('3 hidden, 58 available'), findsOneWidget);
    });

    testWidgets('LOCATION_UNKNOWN is distinguishable from AT_HOME',
        (tester) async {
      // The core of the bug being fixed: these two apply the identical sweep,
      // so without this the phone gives no way to tell them apart.
      await _pump(tester, _record(reason: 'LOCATION_UNKNOWN', distanceM: null));
      expect(find.text('LOCATION UNKNOWN'), findsOneWidget);
      expect(find.textContaining('as if you were at home'), findsOneWidget);
      expect(find.text('unknown - no location fix'), findsOneWidget);
    });

    testWidgets('a missing home is called out rather than shown as AT_HOME',
        (tester) async {
      await _pump(tester, _record(homeConfigured: false));
      expect(find.text('NO HOME SET'), findsOneWidget);
      expect(find.text('no home set'), findsOneWidget);
    });

    testWidgets('a failed pass reports the failure', (tester) async {
      await _pump(tester, _record(failure: 'policy unreadable'));
      expect(find.text('NO DECISION'), findsOneWidget);
      expect(find.textContaining('policy unreadable'), findsOneWidget);
    });

    testWidgets('an implausibly vague fix is flagged', (tester) async {
      await _pump(tester, _record(fixAccuracyM: 1400.0));
      expect(find.textContaining('far wider than the fence'), findsOneWidget);
    });

    testWidgets('curfew renders as active when it is', (tester) async {
      await _pump(tester, _record(reason: 'CURFEW', curfewActive: true));
      expect(find.text('active (23:00-05:00)'), findsOneWidget);
    });

    testWidgets('a stalled schedule is called out', (tester) async {
      await _pump(tester, _record(tsOffsetMinutes: 90));
      expect(find.textContaining('schedule may have stalled'), findsOneWidget);
    });

    testWidgets('changes made this pass are shown when non-zero',
        (tester) async {
      await _pump(tester, _record(hidDelta: 2));
      expect(find.text('hid 2, restored 0'), findsOneWidget);
    });

    testWidgets('each hidden app can be expanded to show why', (tester) async {
      await _pump(tester, _record());
      await tester.tap(find.textContaining('Why these 1 apps are hidden'));
      await tester.pumpAndSettle();
      expect(find.text('com.google.android.youtube'), findsOneWidget);
      expect(find.text('always blocked, everywhere'), findsOneWidget);
    });

    testWidgets('no hidden apps means no expander', (tester) async {
      await _pump(tester, _record(hidden: const []));
      expect(find.textContaining('Why these'), findsNothing);
    });

    testWidgets('never renders anything that looks like a coordinate',
        (tester) async {
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
      await tester.tap(find.text('Debug log'));
      expect(opened, isTrue);
    });
  });

  group('DebugLogPage', () {
    testWidgets('explains itself when empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: DebugLogPage(records: [])),
      );
      expect(find.textContaining('No passes recorded yet'), findsOneWidget);
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
      expect(find.text('AWAY'), findsOneWidget);
      expect(find.text('10.4 km (fence 180 m)'), findsOneWidget);

      await tester.tap(find.text('AWAY'));
      await tester.pumpAndSettle();
      expect(find.text('Fix'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('a failed pass is marked in the list', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DebugLogPage(records: [_record(failure: 'policy unreadable')]),
        ),
      );
      expect(find.text('NO DECISION'), findsOneWidget);
      await tester.tap(find.text('NO DECISION'));
      await tester.pumpAndSettle();
      expect(find.text('Failure'), findsOneWidget);
    });

    testWidgets('copying a record does not throw', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: DebugLogPage(records: [_record()])),
      );
      await tester.tap(find.text('AT HOME'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
    });
  });
}
