// Lockdown event records and the lockdown hide reason, as the Kotlin side
// writes them (LockdownEventRecord.kt, HideReason.NOT_IN_LOCKDOWN_ALLOWLIST).

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/enforcement_record.dart';

Map<String, Object?> _event(String reason, {Object? through}) => {
  'v': 1,
  'ts': 1786000000000,
  'reason': reason,
  'failure': null,
  'counts': {'to_hide': 0, 'to_show': 0},
  'hidden': <Object?>[],
  'lockdown': {'through': through, 'previous': null},
};

Map<String, Object?> _pass(String reason, int hidden) => {
  'v': 1,
  'ts': 1785999999000,
  'reason': reason,
  'failure': null,
  'counts': {'to_hide': hidden, 'to_show': 3},
  'hidden': [
    {'pkg': 'com.metrolist.music', 'why': 'NOT_IN_LOCKDOWN_ALLOWLIST'},
  ],
};

void main() {
  test('the lockdown hide reason parses and explains itself', () {
    final record = EnforcementRecord.fromJson(_pass('WORKDAY_LOCKDOWN', 1));
    expect(record.hidden.single.reason, HideReason.notInLockdownAllowlist);
    expect(
      record.hidden.single.reason.explanation,
      'not on the lockdown allowlist',
    );
    expect(record.isLockdownEvent, isFalse);
    expect(record.explanation, contains('lockdown allowlist'));
  });

  test('event records carry the through-date into the explanation', () {
    final cases = {
      'LOCKDOWN_ACTIVATED': 'started, through 2026-10-03',
      'LOCKDOWN_EXTENDED': 'extended through 2026-10-03',
      'LOCKDOWN_UNCHANGED': 'already locked through 2026-10-03',
    };
    cases.forEach((reason, expected) {
      final record = EnforcementRecord.fromJson(
        _event(reason, through: '2026-10-03'),
      );
      expect(record.isLockdownEvent, isTrue);
      expect(record.lockdownThrough, '2026-10-03');
      expect(record.explanation, contains(expected));
    });
  });

  test('a lift has no through-date', () {
    final record = EnforcementRecord.fromJson(_event('LOCKDOWN_LIFTED'));
    expect(record.lockdownThrough, isNull);
    expect(record.explanation, 'Workday lockdown lifted.');
  });

  test('latestPass skips events so the status card shows the pass', () {
    final records = [
      EnforcementRecord.fromJson(_event('LOCKDOWN_ACTIVATED', through: 'x')),
      EnforcementRecord.fromJson(_pass('WORKDAY_LOCKDOWN', 7)),
    ];
    expect(EnforcementRecord.latestPass(records)?.hideCount, 7);
    expect(EnforcementRecord.latestPass(records.sublist(0, 1)), isNull);
    expect(EnforcementRecord.latestPass(const []), isNull);
  });
}
