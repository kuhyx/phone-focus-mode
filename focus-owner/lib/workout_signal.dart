import 'dart:async';

/// Something that can report whether a workout is currently in progress.
///
/// The rooted system read StrongLifts' SQLite database directly, which an
/// unrooted app cannot do — another app's private storage is unreachable. The
/// replacement is several weaker signals OR'd together.
///
/// Every source must fail *closed*: an error or an unknown state reports "no
/// workout", so a broken source cannot silently unlock YouTube. A source that
/// always returns false is useless but harmless; one that always returns true
/// would quietly disable the exception it exists to gate.
abstract class WorkoutSignal {
  /// Short name, for logging and for the UI to explain why YouTube is open.
  String get name;

  /// Whether this source currently reports a workout in progress.
  Future<bool> isActive();
}

/// A workout the user declared, valid for a fixed window.
///
/// The only source that works unconditionally, so it is the fallback the
/// others are layered on top of. It is time-boxed rather than a plain toggle
/// because an untimed "workout mode" left on by accident is indistinguishable
/// from having no exception at all.
class ManualWorkoutSignal implements WorkoutSignal {
  ManualWorkoutSignal({
    required this.maxDuration,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// How long a declared workout stays valid before it lapses.
  final Duration maxDuration;

  final DateTime Function() _clock;
  DateTime? _startedAt;

  @override
  String get name => 'manual';

  /// Declares a workout as starting now.
  void start() => _startedAt = _clock();

  /// Ends a declared workout immediately.
  void stop() => _startedAt = null;

  /// How much of the window remains, or null when no workout is declared.
  Duration? get remaining {
    final started = _startedAt;
    if (started == null) return null;
    final left = maxDuration - _clock().difference(started);
    return left.isNegative ? null : left;
  }

  @override
  Future<bool> isActive() async => remaining != null;
}

/// A source backed by an asynchronous lookup that may fail.
///
/// Wraps [probe] so that a thrown exception or a timeout reads as "no
/// workout" rather than propagating into the enforcement loop. Used for the
/// Health Connect path, where the query crosses a process boundary and can
/// fail for reasons that have nothing to do with whether the user is training.
class GuardedWorkoutSignal implements WorkoutSignal {
  const GuardedWorkoutSignal({
    required this.name,
    required this.probe,
    this.timeout = const Duration(seconds: 5),
  });

  @override
  final String name;

  /// The underlying lookup.
  final Future<bool> Function() probe;

  /// How long to wait before treating the lookup as failed.
  final Duration timeout;

  @override
  Future<bool> isActive() async {
    try {
      return await probe().timeout(timeout);
    } on Object {
      // Deliberately broad: this sits in the enforcement loop, and no failure
      // of a workout probe should be able to stop enforcement running.
      return false;
    }
  }
}

/// Combines several sources, reporting active if any of them does.
class CombinedWorkoutSignal implements WorkoutSignal {
  const CombinedWorkoutSignal(this.sources);

  final List<WorkoutSignal> sources;

  @override
  String get name => 'combined';

  /// The name of the first source reporting a workout, or null if none is.
  ///
  /// Exposed so the UI can say *which* signal opened the exception; "YouTube
  /// is available because Health Connect sees a session" is far easier to
  /// trust, or to disbelieve, than an unexplained unlock.
  Future<String?> activeSource() async {
    for (final source in sources) {
      if (await source.isActive()) return source.name;
    }
    return null;
  }

  @override
  Future<bool> isActive() async => (await activeSource()) != null;
}
