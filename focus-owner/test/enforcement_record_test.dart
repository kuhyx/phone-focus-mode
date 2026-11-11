import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/enforcement_record.dart';

Map<String, Object?> _doc({
  String reason = 'AT_HOME',
  Object? distanceM = 42.0,
  Object? fixAgeMs = 45000,
  Object? fixAccuracyM = 12.0,
  Object? curfewActive = false,
  Object? homeConfigured = true,
  Object? failure,
}) =>
    {
      'v': 1,
      'ts': 1786000000000,
      'reason': reason,
      'distance_m': distanceM,
      'threshold_m': 180.0,
      'inside_fence': true,
      'home_configured': homeConfigured,
      'fix': {
        'age_ms': fixAgeMs,
        'provider': 'gps',
        'accuracy_m': fixAccuracyM,
        'outcome': 'ACTIVE_OK',
      },
      'curfew_active': curfewActive,
      'curfew_window': '23:00-05:00',
      'counts': {
        'to_hide': 12,
        'to_show': 30,
        'hid_delta': 1,
        'restored_delta': 0,
      },
      'hidden': [
        {'pkg': 'com.google.android.youtube', 'why': 'ALWAYS_BLOCKED'},
        {'pkg': 'org.mozilla.fenix', 'why': 'NOT_IN_ALLOWLIST'},
      ],
      'failure': failure,
    };

void main() {
  group('EnforcementRecord.fromJson', () {
    test('parses a full record', () {
      final record = EnforcementRecord.fromJson(_doc());
      expect(record.reason, 'AT_HOME');
      expect(record.distanceM, 42.0);
      expect(record.thresholdM, 180.0);
      expect(record.fixProvider, 'gps');
      expect(record.hideCount, 12);
      expect(record.showCount, 30);
      expect(record.hidden.length, 2);
      expect(record.hidden.first.reason, HideReason.alwaysBlocked);
    });

    test('tolerates every optional field being absent', () {
      // An older build's record must render rather than crash the one screen
      // that exists to explain what went wrong.
      final record = EnforcementRecord.fromJson({'reason': 'AWAY'});
      expect(record.reason, 'AWAY');
      expect(record.distanceM, isNull);
      expect(record.fixAgeMs, isNull);
      expect(record.hidden, isEmpty);
      expect(record.hideCount, 0);
    });

    test('an unknown hide reason degrades rather than throwing', () {
      final record = EnforcementRecord.fromJson(
        _doc()
          ..['hidden'] = [
            {'pkg': 'com.x', 'why': 'SOMETHING_NEW'},
          ],
      );
      expect(record.hidden.single.reason, HideReason.unknown);
      expect(record.hidden.single.reason.explanation, isNotEmpty);
    });
  });

  group('parseLines', () {
    test('skips a corrupt line instead of losing the history', () {
      final lines = [
        jsonEncode(_doc(reason: 'AWAY')),
        '{half-written',
        jsonEncode(_doc()),
      ];
      final records = EnforcementRecord.parseLines(lines);
      expect(records.length, 2);
      expect(records.first.reason, 'AWAY');
    });

    test('an empty list parses to no records', () {
      expect(EnforcementRecord.parseLines([]), isEmpty);
    });

    test('a wrong-typed field is skipped, not thrown', () {
      // Valid JSON, wrong type. Catching only FormatException let this throw
      // TypeError all the way out of _refresh(), which left the page stuck
      // busy and DISABLED the release-device-owner button -- the one control
      // that has to work when everything else has gone wrong.
      final records = EnforcementRecord.parseLines([
        '{"v":1,"ts":123,"reason":42}',
        jsonEncode(_doc()),
      ]);
      expect(records, hasLength(1));
      expect(records.single.reason, 'AT_HOME');
    });

    test('a wrong-typed nested field is skipped too', () {
      expect(
        EnforcementRecord.parseLines(['{"ts":1,"reason":"AWAY","counts":7}']),
        hasLength(1),
      );
      expect(
        EnforcementRecord.parseLines(['{"ts":"not-a-number","reason":"AWAY"}']),
        isEmpty,
      );
    });
  });

  group('explanations', () {
    test('LOCATION_UNKNOWN says it is blocking as if at home', () {
      // The whole point: this state used to be indistinguishable from AT_HOME.
      final record = EnforcementRecord.fromJson(
        _doc(reason: 'LOCATION_UNKNOWN', distanceM: null, fixAgeMs: null),
      );
      expect(record.locationUnknown, isTrue);
      expect(record.explanation, contains('as if you were at home'));
      expect(record.distanceLabel, 'unknown - no location fix');
    });

    test('a missing home outranks the reason', () {
      // With no coordinates the fence reports "inside" and the reason reads
      // AT_HOME, which would otherwise claim the phone is home anywhere.
      final record = EnforcementRecord.fromJson(_doc(homeConfigured: false));
      expect(record.homeMissing, isTrue);
      expect(record.explanation, contains('No home location is set'));
      expect(record.distanceLabel, 'no home set');
    });

    test('a failed pass explains itself', () {
      final record = EnforcementRecord.fromJson(
        _doc(failure: 'policy unreadable - no decision made'),
      );
      expect(record.explanation, contains('policy unreadable'));
    });

    test('AWAY notes that always-blocked apps stay hidden', () {
      final record = EnforcementRecord.fromJson(_doc(reason: 'AWAY'));
      expect(record.explanation, contains('always-blocked'));
    });
  });

  group('formatting', () {
    test('distances over a kilometre render as km', () {
      final record = EnforcementRecord.fromJson(_doc(distanceM: 10400.0));
      expect(record.distanceLabel, '10.4 km (fence 180 m)');
    });

    test('short distances render as metres', () {
      expect(
        EnforcementRecord.fromJson(_doc(distanceM: 142.0)).distanceLabel,
        '142 m (fence 180 m)',
      );
    });

    test('the fix line carries age, provider, accuracy and outcome', () {
      final record = EnforcementRecord.fromJson(_doc());
      expect(record.fixLabel, '45 s old · gps · ±12 m · active_ok');
    });

    test('an older fix renders in minutes', () {
      final record = EnforcementRecord.fromJson(_doc(fixAgeMs: 1500000));
      expect(record.fixLabel, startsWith('25 min old'));
    });

    test('no fix falls back to the outcome', () {
      final record = EnforcementRecord.fromJson(_doc(fixAgeMs: null));
      expect(record.fixLabel, 'active_ok');
    });

    test('a very vague fix is flagged as probably not precise', () {
      // Coarse location is fuzzed to a ~1-2 km grid, which is the tell that
      // FINE is not actually in effect against a 150 m fence.
      expect(
        EnforcementRecord.fromJson(_doc(fixAccuracyM: 1400.0)).fixLooksFuzzed,
        isTrue,
      );
      expect(EnforcementRecord.fromJson(_doc()).fixLooksFuzzed, isFalse);
    });
  });
}
