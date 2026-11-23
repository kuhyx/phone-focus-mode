/// focus-owner's own record under `wake-alarm-sync/devices-e2e/focus-owner/`.
///
/// Push-only. focus-owner never merges a peer's log into its own file:
/// `crdt_sync` merges a field last-writer-wins, so a pulled phone list could
/// replace the queued `bypass` events, and the phone's tags, home location
/// and weigh-ins would land in a second device directory that diet_guard
/// reads. Peers are read for one thing only, the alarm time ([newestAlarm]).
///
/// The `phone_events` field is stamped at the newest event's own `at`, not
/// at push time: a retry that lands late can never out-rank a newer list the
/// reinstalled phone published (the phone's sync does merge this file).
library;

import 'package:crdt_sync/crdt_sync.dart';

/// This device's directory name; the PC skips it when dating the phone's
/// last push (wake-alarm `FOCUS_OWNER_DEVICE_ID`).
const ownerDeviceId = 'focus-owner';

/// The record every wake-alarm reader looks in.
const alarmRecordId = 'alarm';

/// The field the PC reads events from (wake-alarm `PHONE_EVENTS_FIELD`).
const phoneEventsField = 'phone_events';

/// A harmless field no PC policy reads, for the one real-device check.
const installCheckField = 'install_check';

/// The alarm time the phone published.
typedef AlarmTime = ({int hour, int minute});

/// focus-owner's log holding [events] (newest first) and/or an
/// [installCheckAt] marker.
Log ownerLog({
  List<Map<String, Object?>>? events,
  DateTime? installCheckAt,
}) {
  final fields = <String, (Object?, Hlc)>{};
  final newest = events == null || events.isEmpty
      ? null
      : DateTime.tryParse('${events.first['at']}');
  if (events != null && newest != null) {
    fields[phoneEventsField] = (events, _stamp(newest));
  }
  if (installCheckAt != null) {
    fields[installCheckField] = (
      {'at': installCheckAt.toIso8601String(), 'present': true},
      _stamp(installCheckAt),
    );
  }
  return {alarmRecordId: Record(id: alarmRecordId, fields: fields)};
}

Hlc _stamp(DateTime at) => Hlc(
  wallTimeMs: at.millisecondsSinceEpoch,
  counter: 0,
  nodeId: ownerDeviceId,
);

/// The newest `alarm_hour`/`alarm_minute` by HLC across [logs] (device id
/// to raw JSON), skipping focus-owner's own and anything that does not parse.
AlarmTime? newestAlarm(Map<String, String> logs) {
  (Hlc, AlarmTime)? best;
  for (final MapEntry(key: device, value: text) in logs.entries) {
    if (device == ownerDeviceId) continue;
    final Log log;
    try {
      log = logFromJson(text);
    } on Object {
      continue;
    }
    final fields = log[alarmRecordId]?.fields;
    final hour = fields?['alarm_hour'];
    final minute = fields?['alarm_minute'];
    if (hour == null || minute == null) continue;
    final (h, hlc) = hour;
    final m = minute.$1;
    if (h is! int || m is! int) continue;
    if (best == null || hlc.compareTo(best.$1) > 0) {
      best = (hlc, (hour: h, minute: m));
    }
  }
  return best?.$2;
}
