import 'package:crdt_sync/crdt_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/sync/backend.dart';
import 'package:focus_owner/sync/owner_log.dart';
import 'package:focus_owner/sync/publish.dart';

/// A RemoteStore over a map: path -> text.
class _MapStore implements RemoteStore {
  final files = <String, String>{};
  bool fail = false;

  @override
  Future<List<String>> listDirectory(String path) async => {
    for (final p in files.keys)
      if (p.startsWith('$path/')) p.substring(path.length + 1).split('/').first,
  }.toList();

  @override
  Future<String?> getFileText(String path) async => files[path];

  @override
  Future<void> putFileText(String path, String text, {required String message}) async {
    if (fail) throw StateError('offline');
    files[path] = text;
  }

  @override
  Future<void> deleteFile(String path, {String message = ''}) async => files.remove(path);

  @override
  Future<bool> canAccessRemote() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final own = '${alarmLayout.prefix}/$ownerDeviceId/alarm.json';
  final event = <String, Object?>{
    'at': '2026-11-23T12:30:00+01:00',
    'kind': 'bypass',
    'data': {'cause': 'uninstalled', 'date': '2026-11-23'},
  };
  final phoneHlc = Hlc(wallTimeMs: DateTime.utc(2026, 11, 22).millisecondsSinceEpoch, counter: 0, nodeId: 'p');

  _MapStore withPhone() => _MapStore()
    ..files['${alarmLayout.prefix}/p/alarm.json'] = logToJson({
      'alarm': Record(
        id: 'alarm',
        fields: {
          'alarm_hour': (7, phoneHlc),
          'alarm_minute': (10, phoneHlc),
          'nfc_tags': (['x'], phoneHlc),
        },
      ),
    });

  test('pushes the events and reads the phone alarm', () async {
    final store = withPhone();
    final r = await publishOnce(events: [event], unsent: true, open: () async => store);
    expect(r.pushed, isTrue);
    expect(r.alarm, (hour: 7, minute: 10));
    final log = logFromJson(store.files[own]!);
    expect(log['alarm']!.fields['phone_events']!.$1, [event]);
    // Push-only: no peer field is adopted.
    expect(log['alarm']!.fields.keys, isNot(contains('nfc_tags')));
    expect(log['alarm']!.fields.keys, isNot(contains('alarm_hour')));
  });

  test('keeps an earlier install_check in our own file', () async {
    final store = withPhone()
      ..files[own] = logToJson(ownerLog(installCheckAt: DateTime.utc(2026, 11, 20)));
    await publishOnce(events: [event], unsent: true, open: () async => store);
    final fields = logFromJson(store.files[own]!)['alarm']!.fields;
    expect(fields.keys, containsAll(['phone_events', 'install_check']));
  });

  test('nothing unsent reads the alarm and writes nothing', () async {
    final store = withPhone();
    final r = await publishOnce(events: [event], unsent: false, open: () async => store);
    expect(r.pushed, isNull);
    expect(r.error, isNull);
    expect(store.files.containsKey(own), isFalse);
  });

  test('a failed push reports false with the error and keeps the alarm', () async {
    final store = withPhone()..fail = true;
    final r = await publishOnce(events: [event], unsent: true, open: () async => store);
    expect(r.pushed, isFalse);
    expect(r.alarm, (hour: 7, minute: 10));
    expect(r.error, contains('offline'));
  });

  test('no backend is a failure when unsent', () async {
    final r = await publishOnce(events: [event], unsent: true, open: () async => null);
    expect(r.pushed, isFalse);
    expect(r.error, 'no backend');
  });
}
