import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/theme.dart';

/// The enforcement history, newest first.
///
/// This screen is the deliverable for "extensive debug log to see when it does
/// not work". It has to live in the app: logcat rotates away within minutes
/// (measured empty while `dumpsys alarm` reported 82 alarms had fired) and
/// `run-as` is refused on the release build device owner requires, so neither
/// adb route can read the history.
class DebugLogPage extends StatelessWidget {
  const DebugLogPage({required this.records, super.key});

  final List<EnforcementRecord> records;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kField,
      appBar: AppBar(
        backgroundColor: kField,
        foregroundColor: kText,
        title: const Text('Enforcement log'),
      ),
      body: records.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(kGap * 2),
                child: Text(
                  'No passes recorded yet.\n\n'
                  'Each enforcement pass appends one entry here, so this fills '
                  'up on its own every 15 minutes.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kMuted, height: 1.4),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(kGap),
              itemCount: records.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) => _Entry(record: records[index]),
            ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({required this.record});

  final EnforcementRecord record;

  @override
  Widget build(BuildContext context) {
    // Material, not a decorated box: ExpansionTile paints its ink on the
    // nearest Material ancestor and a DecoratedBox in between hides it.
    return Material(
      color: kSurface,
      borderRadius: BorderRadius.circular(6),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Row(
            children: [
              Text(
                _clock(record.timestamp),
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
              const SizedBox(width: kGap / 2),
              Expanded(
                child: Text(
                  record.failure != null
                      ? 'NO DECISION'
                      : record.reason.replaceAll('_', ' '),
                  style: TextStyle(
                    color: record.failure != null || record.locationUnknown
                        ? kDanger
                        : kText,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                record.distanceLabel,
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kGap, 0, kGap, kGap),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _line('When', record.timestamp.toString()),
                  _line('Fix', record.fixLabel),
                  _line(
                    'Curfew',
                    switch (record.curfewActive) {
                      true => 'active',
                      false => 'inactive',
                      null => 'unknown',
                    },
                  ),
                  _line('Home set', '${record.homeConfigured ?? "unknown"}'),
                  _line('Inside fence', '${record.insideFence ?? "unanswerable"}'),
                  _line(
                    'Counts',
                    '${record.hideCount} hidden / ${record.showCount} shown · '
                        'hid ${record.hidNow}, restored ${record.restoredNow}',
                  ),
                  if (record.failure != null)
                    _line('Failure', record.failure!, danger: true),
                  if (record.hidden.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    const Text(
                      'Hidden',
                      style: TextStyle(color: kMuted, fontSize: 12),
                    ),
                    for (final h in record.hidden)
                      Text(
                        '  ${h.package} — ${h.reason.explanation}',
                        style: const TextStyle(color: kText, fontSize: 11),
                      ),
                  ],
                  const SizedBox(height: 6),
                  // Lets a record leave the phone without adb, which is the
                  // only other way it could be shared.
                  TextButton(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: _asText(record)),
                    ),
                    child: const Text('Copy'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _line(String label, String value, {bool danger = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                label,
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  color: danger ? kDanger : kText,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      );

  static String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';

  static String _asText(EnforcementRecord r) => [
        'when: ${r.timestamp}',
        'reason: ${r.reason}',
        'distance: ${r.distanceLabel}',
        'fix: ${r.fixLabel}',
        'curfew active: ${r.curfewActive}',
        'home configured: ${r.homeConfigured}',
        'inside fence: ${r.insideFence}',
        'hidden: ${r.hideCount}, shown: ${r.showCount}',
        'hid now: ${r.hidNow}, restored now: ${r.restoredNow}',
        if (r.failure != null) 'failure: ${r.failure}',
        for (final h in r.hidden) '  ${h.package} (${h.reason.explanation})',
      ].join('\n');
}
