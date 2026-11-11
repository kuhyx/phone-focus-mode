// Fixtures and finders for enforcement_status_card_test.dart. A part so the
// helpers stay library-private and the test file stays under 250 lines.

part of 'enforcement_status_card_test.dart';

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
