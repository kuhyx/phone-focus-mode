import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/workout_signal.dart';

/// A source with a fixed answer, for exercising the combinator.
class _Fixed implements WorkoutSignal {
  const _Fixed(this.name, this.value);

  @override
  final String name;
  final bool value;

  @override
  Future<bool> isActive() async => value;
}

void main() {
  group('ManualWorkoutSignal', () {
    late DateTime now;
    late ManualWorkoutSignal signal;

    setUp(() {
      now = DateTime(2026, 8, 9, 12);
      signal = ManualWorkoutSignal(
        maxDuration: const Duration(minutes: 90),
        clock: () => now,
      );
    });

    test('is inactive until a workout is declared', () async {
      expect(await signal.isActive(), isFalse);
      expect(signal.remaining, isNull);
    });

    test('is active once started', () async {
      signal.start();
      expect(await signal.isActive(), isTrue);
      expect(signal.remaining, const Duration(minutes: 90));
    });

    test('lapses when the window expires', () async {
      // Time-boxed rather than a plain toggle: a "workout mode" left on by
      // accident is indistinguishable from having no exception at all.
      signal.start();
      now = now.add(const Duration(minutes: 89));
      expect(await signal.isActive(), isTrue);
      now = now.add(const Duration(minutes: 2));
      expect(await signal.isActive(), isFalse);
      expect(signal.remaining, isNull);
    });

    test('stop ends it immediately', () async {
      signal.start();
      signal.stop();
      expect(await signal.isActive(), isFalse);
    });

    test('restarting extends the window from the new start', () async {
      signal.start();
      now = now.add(const Duration(minutes: 80));
      signal.start();
      expect(signal.remaining, const Duration(minutes: 90));
    });
  });

  group('GuardedWorkoutSignal', () {
    test('passes through a successful probe', () async {
      const signal = GuardedWorkoutSignal(name: 'hc', probe: _alwaysTrue);
      expect(await signal.isActive(), isTrue);
    });

    test('a throwing probe reads as no workout', () async {
      // Fail closed: a broken probe must not unlock YouTube.
      const signal = GuardedWorkoutSignal(name: 'hc', probe: _alwaysThrows);
      expect(await signal.isActive(), isFalse);
    });

    test('a hanging probe times out to no workout', () async {
      const signal = GuardedWorkoutSignal(
        name: 'hc',
        probe: _neverCompletes,
        timeout: Duration(milliseconds: 50),
      );
      expect(await signal.isActive(), isFalse);
    });
  });

  group('CombinedWorkoutSignal', () {
    test('is inactive when every source is', () async {
      const combined = CombinedWorkoutSignal([
        _Fixed('a', false),
        _Fixed('b', false),
      ]);
      expect(await combined.isActive(), isFalse);
      expect(await combined.activeSource(), isNull);
    });

    test('is active when any source is', () async {
      const combined = CombinedWorkoutSignal([
        _Fixed('a', false),
        _Fixed('b', true),
      ]);
      expect(await combined.isActive(), isTrue);
    });

    test('names the source that opened the exception', () async {
      // So the UI can explain the unlock rather than presenting it as magic.
      const combined = CombinedWorkoutSignal([
        _Fixed('manual', false),
        _Fixed('health_connect', true),
      ]);
      expect(await combined.activeSource(), 'health_connect');
    });

    test('with no sources it is inactive', () async {
      const combined = CombinedWorkoutSignal([]);
      expect(await combined.isActive(), isFalse);
    });
  });
}

Future<bool> _alwaysTrue() async => true;
Future<bool> _alwaysThrows() async => throw StateError('probe failed');
Future<bool> _neverCompletes() => Completer<bool>().future;
