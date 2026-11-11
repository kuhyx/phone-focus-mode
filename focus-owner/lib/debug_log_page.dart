import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/enforcement_status_card.dart';
import 'package:focus_owner/record_values.dart';
import 'package:focus_owner/state_glyphs.dart';
import 'package:focus_owner/theme.dart';

/// The enforcement history, newest first.
///
/// This screen is the deliverable for "extensive debug log to see when it does
/// not work". It has to live in the app: logcat rotates away within minutes
/// (measured empty while `dumpsys alarm` reported 82 alarms had fired) and
/// `run-as` is refused on the release build device owner requires, so neither
/// adb route can read the history.
///
/// Text-free like the status card: each field is an icon plus a glyph or a
/// number. The copy button still exports the full wording as plain text.
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
        title: const Icon(Icons.receipt_long, semanticLabel: 'Enforcement log'),
      ),
      body: records.isEmpty
          ? const Center(
              child: Icon(
                Icons.hourglass_empty,
                key: Key('log-empty'),
                size: 48,
                color: kMuted,
                semanticLabel: 'No passes recorded yet',
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
    final r = record;
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
                _clock(r.timestamp),
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
              const SizedBox(width: kGap / 2),
              GlyphIcon(reasonGlyph(r), spoken: r.explanation, size: 22),
              const SizedBox(width: kGap / 2),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: DistanceValue(r),
                ),
              ),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kGap, 0, kGap, kGap),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _line(
                    Icons.schedule,
                    Text(
                      r.timestamp.toString(),
                      style: const TextStyle(color: kText, fontSize: 12),
                    ),
                  ),
                  _line(Icons.gps_fixed, FixValue(r)),
                  _line(Icons.bedtime, CurfewValue(r)),
                  _line(
                    Icons.home,
                    GlyphIcon(
                      boolGlyph(r.homeConfigured, falseIsBad: true),
                      spoken: 'home set: ${r.homeConfigured ?? "unknown"}',
                    ),
                  ),
                  _line(
                    Icons.fence,
                    GlyphIcon(
                      boolGlyph(r.insideFence),
                      spoken:
                          'inside fence: ${r.insideFence ?? "unanswerable"}',
                    ),
                  ),
                  _line(Icons.apps, CountsValue(r)),
                  if (r.failure != null)
                    _line(
                      Icons.error,
                      GlyphIcon(
                        const Glyph(Icons.cancel, kDanger),
                        spoken: 'Failure: ${r.failure}',
                      ),
                    ),
                  for (final h in r.hidden) HiddenEntry(h),
                  // Lets a record leave the phone without adb, which is the
                  // only other way it could be shared.
                  TextButton(
                    key: const Key('log-copy'),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: _asText(r))),
                    child: const Icon(Icons.copy, semanticLabel: 'Copy'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _line(IconData icon, Widget value) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Icon(icon, size: 16, color: kMuted),
        const SizedBox(width: kGap),
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: value,
          ),
        ),
      ],
    ),
  );

  static String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';

  /// Plain-text export for the clipboard; never painted.
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
