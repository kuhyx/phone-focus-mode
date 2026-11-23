import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/sync/owner_log.dart';
import 'package:focus_owner/sync/sync_emulator.dart';

String _alarmLog(String node, int hour, int minute, DateTime at) {
  final hlc = Hlc(wallTimeMs: at.millisecondsSinceEpoch, counter: 0, nodeId: node);
  return logToJson({
    'alarm': Record(
      id: 'alarm',
      fields: {'alarm_hour': (hour, hlc), 'alarm_minute': (minute, hlc)},
    ),
  });
}

void main() {
  final bypass = <String, Object?>{
    'at': '2026-11-24T07:30:05+01:00',
    'kind': 'bypass',
    'data': {'cause': 'uninstalled', 'date': '2026-11-24'},
  };

  test('the device id is focus-owner', () {
    expect(ownerDeviceId, 'focus-owner');
  });

  test('events ride on record alarm, field phone_events, stamped at the newest event', () {
    final log = ownerLog(events: [bypass]);
    final (value, hlc) = log['alarm']!.fields['phone_events']!;
    expect(value, [bypass]);
    expect(
      hlc.wallTimeMs,
      DateTime.parse('2026-11-24T07:30:05+01:00').millisecondsSinceEpoch,
    );
    expect(hlc.nodeId, ownerDeviceId);
    final decoded = jsonDecode(logToJson(log)) as Map<String, Object?>;
    expect(decoded.keys, contains('alarm'));
  });

  test('a later event list replaces an older one on merge with the own file', () {
    final older = ownerLog(events: [
      {...bypass, 'at': '2026-11-23T03:00:00+01:00'},
    ]);
    final newer = ownerLog(events: [bypass]);
    final merged = mergeLogs(older, newer);
    expect(merged['alarm']!.fields['phone_events']!.$1, [bypass]);
  });

  test('install_check rides beside the events without touching them', () {
    final at = DateTime.utc(2026, 11, 23, 12);
    final log = ownerLog(installCheckAt: at);
    expect(log['alarm']!.fields.containsKey('phone_events'), isFalse);
    expect(log['alarm']!.fields['install_check']!.$1, {
      'at': at.toIso8601String(),
      'present': true,
    });
  });

  test('the alarm time is the newest by HLC across devices, never our own', () {
    final logs = {
      'old-phone': _alarmLog('old-phone', 8, 0, DateTime.utc(2026, 11, 1)),
      'phone-uuid': _alarmLog('phone-uuid', 7, 15, DateTime.utc(2026, 11, 20)),
      ownerDeviceId: _alarmLog(ownerDeviceId, 5, 0, DateTime.utc(2026, 11, 22)),
      'garbled': '{not json',
    };
    expect(newestAlarm(logs), (hour: 7, minute: 15));
  });

  test('no alarm anywhere is null (Kotlin falls back to 08:00)', () {
    expect(newestAlarm({'a': '{}'}), isNull);
    expect(newestAlarm({}), isNull);
  });

  test('an empty emulator define means prod', () {
    expect(kSyncEmulatorUrl, isEmpty);
    expect(syncEmulatorOn, isFalse);
  });
}
