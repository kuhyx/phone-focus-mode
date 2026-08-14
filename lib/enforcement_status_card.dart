import 'package:flutter/material.dart';

import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/theme.dart';

/// Renders the most recent enforcement pass, and why it decided what it did.
///
/// Exists because the three states were indistinguishable from the phone:
/// LOCATION_UNKNOWN applies the identical sweep to AT_HOME, so "no GPS" and
/// "at home" looked the same, and nothing on screen showed the distance the
/// geofence had actually measured. Every field here answers a question that
/// previously required reading logcat, which does not survive long enough.
class EnforcementStatusCard extends StatelessWidget {
  const EnforcementStatusCard({
    required this.record,
    required this.onOpenLog,
    super.key,
  });

  /// The latest pass, or null when none has been recorded yet.
  final EnforcementRecord? record;
  final VoidCallback onOpenLog;

  @override
  Widget build(BuildContext context) {
    final latest = record;
    if (latest == null) {
      return const _Card(
        child: Text(
          'No enforcement pass recorded yet.\n'
          'Tap "Run enforcement now" to make one.',
          style: TextStyle(color: kMuted),
        ),
      );
    }
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _headline(latest),
                  style: TextStyle(
                    color: _reasonColour(latest),
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                _ago(latest.timestamp),
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: kGap / 2),
          Text(
            latest.explanation,
            style: const TextStyle(color: kText, height: 1.35),
          ),
          const SizedBox(height: kGap),
          _Field(label: 'Distance from home', value: latest.distanceLabel),
          _Field(
            label: 'Location fix',
            value: latest.fixLabel,
            danger: latest.fixLooksFuzzed,
          ),
          if (latest.fixLooksFuzzed)
            const _Note(
              text: 'That accuracy is far wider than the fence, so the '
                  'geofence cannot be trusted. Precise location is probably '
                  'not in effect.',
            ),
          _Field(
            label: 'Night curfew',
            value: switch (latest.curfewActive) {
              true => 'active${_window(latest)}',
              false => 'inactive${_window(latest)}',
              null => 'unknown',
            },
          ),
          _Field(
            label: 'Apps',
            value: '${latest.hideCount} hidden, ${latest.showCount} available',
          ),
          if (latest.hidNow > 0 || latest.restoredNow > 0)
            _Field(
              label: 'Changed this pass',
              value: 'hid ${latest.hidNow}, restored ${latest.restoredNow}',
            ),
          if (_isStale(latest.timestamp))
            const _Note(
              text: 'The last pass was over 30 minutes ago. Enforcement runs '
                  'every 15 minutes, so the schedule may have stalled.',
              danger: true,
            ),
          if (latest.hidden.isNotEmpty) ...[
            const SizedBox(height: kGap / 2),
            _HiddenList(hidden: latest.hidden),
          ],
          const SizedBox(height: kGap / 2),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onOpenLog,
              child: const Text('Debug log'),
            ),
          ),
        ],
      ),
    );
  }

  String _headline(EnforcementRecord r) {
    if (r.failure != null) return 'NO DECISION';
    if (r.homeMissing) return 'NO HOME SET';
    return r.reason.replaceAll('_', ' ');
  }

  /// Colour-coded so the state that needs attention stands out.
  Color _reasonColour(EnforcementRecord r) {
    if (r.failure != null || r.homeMissing) return kDanger;
    return switch (r.reason) {
      'LOCATION_UNKNOWN' => kDanger,
      'AWAY' => kMuted,
      'CURFEW' => kWarn,
      _ => kAccent,
    };
  }

  String _window(EnforcementRecord r) =>
      r.curfewWindow == null ? '' : ' (${r.curfewWindow})';

  static bool _isStale(DateTime at) =>
      DateTime.now().difference(at) > const Duration(minutes: 30);

  static String _ago(DateTime at) {
    final delta = DateTime.now().difference(at);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours} h ago';
    return '${delta.inDays} d ago';
  }
}

/// The hidden apps, each with the rule that hid it.
class _HiddenList extends StatelessWidget {
  const _HiddenList({required this.hidden});

  final List<HiddenPackage> hidden;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          'Why these ${hidden.length} apps are hidden',
          style: const TextStyle(color: kAccent, fontSize: 14),
        ),
        children: [
          for (final entry in hidden)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      entry.package,
                      style: const TextStyle(color: kText, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: kGap / 2),
                  Text(
                    entry.reason.explanation,
                    style: TextStyle(
                      color: entry.reason == HideReason.alwaysBlocked
                          ? kDanger
                          : kMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  // A Material rather than a plain decorated box: the hidden-apps
  // ExpansionTile paints its ink on the nearest Material ancestor, and a
  // DecoratedBox in between swallows the ripple.
  @override
  Widget build(BuildContext context) => Material(
        color: kSurface,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(kGap),
          child: child,
        ),
      );
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value, this.danger = false});

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 150,
              child: Text(
                label,
                style: const TextStyle(color: kMuted, fontSize: 13),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  color: danger ? kDanger : kText,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.danger = false});

  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            color: danger ? kDanger : kWarn,
            fontSize: 12,
            height: 1.3,
          ),
        ),
      );
}
