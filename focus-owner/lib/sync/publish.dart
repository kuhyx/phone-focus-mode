/// The headless `publishNowMain` engine (Kotlin `HeadlessPublish`): read the
/// phone's alarm time, push the queued `bypass:uninstalled` events, report.
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' show DartPluginRegistrant;

import 'package:crdt_sync/crdt_sync.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:focus_owner/sync/backend.dart';
import 'package:focus_owner/sync/owner_log.dart';

/// Must match `HeadlessPublish.CHANNEL`.
const publishChannelName = 'com.kuhy.focus_owner/publish';

/// What one run did, for the `done` call.
typedef PublishResult = ({
  bool? pushed,
  AlarmTime? alarm,
  String? error,
});

/// Every peer's raw `alarm.json` under the encrypted prefix.
Future<Map<String, String>> readPeers(RemoteStore sealed) async {
  final out = <String, String>{};
  for (final device in await sealed.listDirectory(alarmLayout.prefix)) {
    if (device == ownerDeviceId) continue;
    try {
      final text = await sealed.getFileText(
        '${alarmLayout.prefix}/$device/alarm.json',
      );
      if (text != null) out[device] = text;
    } on Object catch (e) {
      developer.log('peer $device skipped: $e', name: 'FocusOwnerSync');
    }
  }
  return out;
}

/// Merges [local] into focus-owner's own remote file and writes it back.
/// Only our own file is read: no peer field is ever adopted.
Future<void> pushOwn(RemoteStore sealed, Log local) async {
  final path = '${alarmLayout.prefix}/$ownerDeviceId/alarm.json';
  final remote = await sealed.getFileText(path);
  final merged = remote == null ? local : mergeLogs(logFromJson(remote), local);
  await sealed.putFileText(
    path,
    logToJson(merged),
    message: 'focus_owner: publish',
  );
}

/// One run: alarm time always, events when [unsent]. Never throws.
Future<PublishResult> publishOnce({
  required List<Map<String, Object?>> events,
  required bool unsent,
  Future<RemoteStore?> Function()? open,
}) async {
  AlarmTime? alarm;
  try {
    final backend = await (open ?? _openSealedBackend)();
    if (backend == null) {
      return (pushed: unsent ? false : null, alarm: null, error: 'no backend');
    }
    alarm = newestAlarm(await readPeers(backend));
    if (!unsent) return (pushed: null, alarm: alarm, error: null);
    await pushOwn(backend, ownerLog(events: events));
    return (pushed: true, alarm: alarm, error: null);
  } on Object catch (e) {
    return (pushed: unsent ? false : null, alarm: alarm, error: '$e');
  }
}

// coverage:ignore-start
Future<RemoteStore?> _openSealedBackend() async {
  final backend = await openBackend();
  return backend == null ? null : openSealed(backend);
}

/// Pushes the one harmless `install_check` field (the real-device check
/// after sign-in). Returns whether it reached the backend.
Future<bool> publishInstallCheck() async {
  try {
    final backend = await _openSealedBackend();
    if (backend == null) return false;
    await pushOwn(backend, ownerLog(installCheckAt: DateTime.now().toUtc()));
    return true;
  } on Object catch (e) {
    developer.log('install_check not pushed: $e', name: 'FocusOwnerSync');
    return false;
  }
}

/// The engine's whole job: ask Kotlin for the queue, publish, say done.
Future<void> runHeadlessPublish() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const channel = MethodChannel(publishChannelName);
  var generation = -1;
  PublishResult result = (pushed: null, alarm: null, error: 'not started');
  try {
    final pending = await channel.invokeMapMethod<String, Object?>('pending');
    generation = (pending?['generation'] as int?) ?? -1;
    final events = [
      for (final e in jsonDecode('${pending?['events'] ?? '[]'}') as List)
        (e as Map).cast<String, Object?>(),
    ];
    result = await publishOnce(
      events: events,
      unsent: pending?['unsent'] == true,
    );
  } on Object catch (e) {
    result = (pushed: false, alarm: null, error: '$e');
  } finally {
    developer.log('publish: $result', name: 'FocusOwnerSync');
    try {
      await channel.invokeMethod<void>('done', {
        'pushed': result.pushed,
        'generation': generation,
        'alarm_hour': result.alarm?.hour,
        'alarm_minute': result.alarm?.minute,
        'error': result.error,
      });
    } on Object catch (e) {
      developer.log('done not delivered: $e', name: 'FocusOwnerSync');
    }
  }
}

// coverage:ignore-end
