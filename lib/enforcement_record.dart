import 'dart:convert';

/// Why a package is hidden, mirroring Kotlin's `HideReason`.
enum HideReason {
  alwaysBlocked,
  notInAllowlist,
  notInNightAllowlist,
  unknown;

  static HideReason parse(String? raw) => switch (raw) {
        'ALWAYS_BLOCKED' => HideReason.alwaysBlocked,
        'NOT_IN_ALLOWLIST' => HideReason.notInAllowlist,
        'NOT_IN_NIGHT_ALLOWLIST' => HideReason.notInNightAllowlist,
        _ => HideReason.unknown,
      };

  /// Plain-English explanation shown next to a hidden app.
  String get explanation => switch (this) {
        HideReason.alwaysBlocked => 'always blocked, everywhere',
        HideReason.notInAllowlist => 'not on the day allowlist',
        HideReason.notInNightAllowlist => 'not on the curfew allowlist',
        HideReason.unknown => 'reason not recorded',
      };
}

/// One hidden package and why.
class HiddenPackage {
  const HiddenPackage(this.package, this.reason);

  final String package;
  final HideReason reason;
}

/// One enforcement pass, as written by the Kotlin runner.
///
/// Deliberately a *parser*, not a second decision layer. The Kotlin side is
/// what actually enforces; re-deriving the outcome in Dart is how the two
/// drifted before, and a status screen that computes its own answer can
/// confidently report "nothing blocked" while YouTube is in fact hidden.
/// Everything here comes from the record.
///
/// Parsing is tolerant: a field this build does not recognise, or one written
/// by an older build, renders as unknown rather than throwing. A debug screen
/// that crashes on the malformed record is useless precisely when it matters.
class EnforcementRecord {
  const EnforcementRecord({
    required this.timestamp,
    required this.reason,
    required this.distanceM,
    required this.thresholdM,
    required this.insideFence,
    required this.homeConfigured,
    required this.fixAgeMs,
    required this.fixProvider,
    required this.fixAccuracyM,
    required this.fixOutcome,
    required this.curfewActive,
    required this.curfewWindow,
    required this.hideCount,
    required this.showCount,
    required this.hidNow,
    required this.restoredNow,
    required this.hidden,
    required this.failure,
  });

  /// Parses one JSON-lines record.
  factory EnforcementRecord.fromJson(Map<String, Object?> json) {
    final fix = json['fix'];
    final fixMap = fix is Map<String, Object?> ? fix : const <String, Object?>{};
    final counts = json['counts'];
    final countMap =
        counts is Map<String, Object?> ? counts : const <String, Object?>{};
    return EnforcementRecord(
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (json['ts'] as num?)?.toInt() ?? 0,
      ),
      reason: json['reason'] as String? ?? 'UNKNOWN',
      distanceM: (json['distance_m'] as num?)?.toDouble(),
      thresholdM: (json['threshold_m'] as num?)?.toDouble(),
      insideFence: json['inside_fence'] as bool?,
      homeConfigured: json['home_configured'] as bool?,
      fixAgeMs: (fixMap['age_ms'] as num?)?.toInt(),
      fixProvider: fixMap['provider'] as String?,
      fixAccuracyM: (fixMap['accuracy_m'] as num?)?.toDouble(),
      fixOutcome: fixMap['outcome'] as String?,
      curfewActive: json['curfew_active'] as bool?,
      curfewWindow: json['curfew_window'] as String?,
      hideCount: (countMap['to_hide'] as num?)?.toInt() ?? 0,
      showCount: (countMap['to_show'] as num?)?.toInt() ?? 0,
      hidNow: (countMap['hid_delta'] as num?)?.toInt() ?? 0,
      restoredNow: (countMap['restored_delta'] as num?)?.toInt() ?? 0,
      hidden: _parseHidden(json['hidden']),
      failure: json['failure'] as String?,
    );
  }

  /// Parses the raw lines returned by the platform channel, newest first.
  ///
  /// A line that will not parse is skipped rather than failing the batch: one
  /// truncated record must not cost the whole history.
  static List<EnforcementRecord> parseLines(List<String> lines) {
    final records = <EnforcementRecord>[];
    for (final line in lines) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, Object?>) {
          records.add(EnforcementRecord.fromJson(decoded));
        }
        // Deliberately broad. Catching only FormatException let a
        // syntactically valid line with a wrong-typed field (say
        // `"reason": 42` from a future schema, or a half-overwritten record)
        // throw TypeError instead, and that escaped all the way out of
        // _refresh(), leaving the status page stuck busy -- which disables
        // the release-device-owner button, whose entire purpose is to be
        // reachable when everything else has gone wrong. One unreadable
        // record must never cost the escape hatch.
      } catch (_) {
        continue;
      }
    }
    return records;
  }

  static List<HiddenPackage> _parseHidden(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, Object?>>()
        .map(
          (e) => HiddenPackage(
            e['pkg'] as String? ?? '?',
            HideReason.parse(e['why'] as String?),
          ),
        )
        .toList();
  }

  final DateTime timestamp;
  final String reason;
  final double? distanceM;
  final double? thresholdM;
  final bool? insideFence;
  final bool? homeConfigured;
  final int? fixAgeMs;
  final String? fixProvider;
  final double? fixAccuracyM;
  final String? fixOutcome;
  final bool? curfewActive;
  final String? curfewWindow;
  final int hideCount;
  final int showCount;
  final int hidNow;
  final int restoredNow;
  final List<HiddenPackage> hidden;
  final String? failure;

  /// Whether this pass could not place the phone.
  bool get locationUnknown => reason == 'LOCATION_UNKNOWN';

  /// Whether home was never provisioned, which enforces everywhere.
  ///
  /// Kept distinct from every other state: with no coordinates the fence
  /// reports "inside" and the reason reads AT_HOME, so without this the screen
  /// would claim the phone is at home wherever it actually is.
  bool get homeMissing => homeConfigured == false;

  /// A one-line explanation of [reason], in the user's terms.
  String get explanation {
    if (failure != null) return 'No decision was made: $failure';
    if (homeMissing) {
      return 'No home location is set, so everything is enforced everywhere. '
          'Use "Set home to current location" while you are at home.';
    }
    return switch (reason) {
      'AWAY' => 'Away from home. Everything is available except the '
          'always-blocked apps, which stay hidden wherever you are.',
      'AT_HOME' => 'At home. Only allowlisted apps are available.',
      'CURFEW' => 'Night curfew. The shorter night allowlist applies.',
      'WORKOUT' => 'Workout in progress, so the workout exceptions apply.',
      'LOCATION_UNKNOWN' =>
        'No usable location fix, so the phone is blocking as if you were at '
            'home. Losing GPS must not become a way to switch enforcement off.',
      _ => 'Unrecognised state: $reason',
    };
  }

  /// Distance rendered for humans, or why there is none.
  String get distanceLabel {
    if (homeMissing) return 'no home set';
    final metres = distanceM;
    if (metres == null) return 'unknown - no location fix';
    final threshold = thresholdM;
    final distance =
        metres >= 1000 ? '${(metres / 1000).toStringAsFixed(1)} km' : '${metres.round()} m';
    if (threshold == null) return distance;
    return '$distance (fence ${threshold.round()} m)';
  }

  /// Fix age, provider and accuracy on one line.
  String get fixLabel {
    final age = fixAgeMs;
    if (age == null) return fixOutcome?.toLowerCase() ?? 'no fix';
    final seconds = age ~/ 1000;
    final agePart = seconds >= 60 ? '${seconds ~/ 60} min old' : '$seconds s old';
    final parts = <String>[
      agePart,
      ?fixProvider,
      if (fixAccuracyM != null) '±${fixAccuracyM!.round()} m',
      if (fixOutcome != null) fixOutcome!.toLowerCase(),
    ];
    return parts.join(' · ');
  }

  /// Whether the fix was too vague to trust against a 150 m fence.
  ///
  /// Surfaced because it is the tell that FINE location is not actually in
  /// effect: coarse location is fuzzed to a ~1-2 km grid.
  bool get fixLooksFuzzed => (fixAccuracyM ?? 0) > 500;
}
