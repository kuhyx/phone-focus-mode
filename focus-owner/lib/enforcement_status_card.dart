import 'dart:async';

import 'package:flutter/material.dart';

import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/record_values.dart';
import 'package:focus_owner/state_glyphs.dart';
import 'package:focus_owner/theme.dart';

part 'status_card_parts.dart';

/// Renders the most recent enforcement pass, and why it decided what it did.
///
/// Exists because the three states were indistinguishable from the phone:
/// LOCATION_UNKNOWN applies the identical sweep to AT_HOME, so "no GPS" and
/// "at home" looked the same, and nothing on screen showed the distance the
/// geofence had actually measured. Every field here answers a question that
/// previously required reading logcat, which does not survive long enough.
///
/// Text-free (textgate): the state is a large coloured glyph, the rows are
/// icons and numbers, and the old sentences are spoken labels only.
class EnforcementStatusCard extends StatelessWidget {
  const EnforcementStatusCard({
    required this.record,
    required this.onOpenLog,
    this.onRefreshLocation,
    super.key,
  });

  /// The latest pass, or null when none has been recorded yet.
  final EnforcementRecord? record;
  final VoidCallback onOpenLog;

  /// Tapping a location row re-acquires a fix. Null renders the rows
  /// inert, both while a pass is already running and where there is no
  /// pass to run.
  final VoidCallback? onRefreshLocation;

  @override
  Widget build(BuildContext context) {
    final latest = record;
    if (latest == null) {
      return const _Card(
        child: Center(
          child: Icon(
            Icons.hourglass_empty,
            key: Key('card-empty'),
            size: 40,
            color: kMuted,
            semanticLabel: 'No enforcement pass recorded yet',
          ),
        ),
      );
    }
    final stale = isStale(latest.timestamp, DateTime.now());
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GlyphIcon(
                reasonGlyph(latest),
                spoken: latest.explanation,
                size: 40,
                key: const Key('card-state'),
              ),
              const Spacer(),
              _Age(at: latest.timestamp, stale: stale),
            ],
          ),
          const SizedBox(height: kGap),
          _Field(
            icon: Icons.home_work,
            onTap: onRefreshLocation,
            key: const Key('row-distance'),
            child: DistanceValue(latest),
          ),
          _Field(
            icon: Icons.gps_fixed,
            onTap: onRefreshLocation,
            key: const Key('row-fix'),
            child: FixValue(latest),
          ),
          _Field(
            icon: Icons.bedtime,
            key: const Key('row-curfew'),
            child: CurfewValue(latest),
          ),
          _Field(
            icon: Icons.apps,
            key: const Key('row-apps'),
            child: CountsValue(latest),
          ),
          // One row: the hidden-apps sheet link and the debug log.
          Row(
            children: [
              if (latest.hidden.isNotEmpty) _HiddenList(hidden: latest.hidden),
              const Spacer(),
              IconButton(
                key: const Key('row-debug'),
                onPressed: onOpenLog,
                icon: const Icon(Icons.bug_report, semanticLabel: 'Debug log'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Over 30 minutes since the last pass: the 15-minute schedule may have
  /// stalled.
  @visibleForTesting
  static bool isStale(DateTime at, DateTime now) =>
      now.difference(at) > const Duration(minutes: 30);
}
