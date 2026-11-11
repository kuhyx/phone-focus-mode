/// The value half of a record row, drawn as icons and numbers.
///
/// Shared by the status card and the debug log so both say the same thing
/// the same way. Each widget carries the old sentence as its spoken label.
library;

import 'package:flutter/material.dart';

import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/state_glyphs.dart';
import 'package:focus_owner/theme.dart';

/// A [Glyph] painted at [size], spoken as [spoken].
class GlyphIcon extends StatelessWidget {
  const GlyphIcon(
    this.glyph, {
    required this.spoken,
    this.size = 18,
    super.key,
  });

  final Glyph glyph;
  final String spoken;
  final double size;

  @override
  Widget build(BuildContext context) =>
      Icon(glyph.icon, color: glyph.color, size: size, semanticLabel: spoken);
}

/// A small muted icon followed by a number: "[eye-off] 3".
class IconNumber extends StatelessWidget {
  const IconNumber(
    this.icon,
    this.value, {
    required this.spoken,
    this.color = kText,
    super.key,
  });

  final IconData icon;
  final String value;
  final String spoken;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: spoken,
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: kMuted),
        const SizedBox(width: 3),
        Text(value, style: TextStyle(color: color, fontSize: 13)),
        const SizedBox(width: kGap / 2),
      ],
    ),
  );
}

/// Distance to home and the fence radius, or why there is none.
class DistanceValue extends StatelessWidget {
  const DistanceValue(this.record, {super.key});

  final EnforcementRecord record;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final spoken = r.distanceLabel;
    if (r.homeMissing) {
      return GlyphIcon(const Glyph(Icons.add_home, kDanger), spoken: spoken);
    }
    final metres = r.distanceM;
    if (metres == null) {
      return GlyphIcon(
        const Glyph(Icons.location_disabled, kDanger),
        spoken: spoken,
      );
    }
    final threshold = r.thresholdM;
    return Semantics(
      label: spoken,
      excludeSemantics: true,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(_metres(metres), style: const TextStyle(color: kText)),
          const SizedBox(width: kGap / 2),
          if (threshold != null)
            IconNumber(Icons.fence, _metres(threshold), spoken: ''),
        ],
      ),
    );
  }
}

/// Fix age, provider, accuracy and outcome as icons and numbers.
///
/// A fuzzed fix (accuracy wider than the fence) paints its accuracy in
/// danger colour and adds a blur glyph: that is the tell that precise
/// location is not in effect.
class FixValue extends StatelessWidget {
  const FixValue(this.record, {super.key});

  final EnforcementRecord record;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final outcome = fixOutcomeGlyph(r.fixOutcome);
    final provider = providerIcon(r.fixProvider);
    final age = r.fixAgeMs;
    final accuracy = r.fixAccuracyM;
    return Semantics(
      label: r.fixLabel,
      excludeSemantics: true,
      child: Wrap(
        spacing: kGap / 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (age == null && outcome == null)
            GlyphIcon(const Glyph(Icons.gps_off, kDanger), spoken: ''),
          if (age != null)
            Text(_seconds(age ~/ 1000), style: const TextStyle(color: kText)),
          if (provider != null) Icon(provider, size: 16, color: kMuted),
          if (accuracy != null)
            Text(
              '±${accuracy.round()} m',
              style: TextStyle(color: r.fixLooksFuzzed ? kDanger : kText),
            ),
          if (r.fixLooksFuzzed)
            GlyphIcon(const Glyph(Icons.blur_on, kWarn), spoken: ''),
          if (outcome != null) GlyphIcon(outcome, spoken: ''),
        ],
      ),
    );
  }
}

/// Hidden and available counts, plus what this pass changed.
class CountsValue extends StatelessWidget {
  const CountsValue(this.record, {super.key});

  final EnforcementRecord record;

  @override
  Widget build(BuildContext context) {
    final r = record;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconNumber(
          Icons.visibility_off,
          '${r.hideCount}',
          spoken: '${r.hideCount} hidden',
        ),
        IconNumber(
          Icons.visibility,
          '${r.showCount}',
          spoken: '${r.showCount} available',
        ),
        if (r.hidNow > 0 || r.restoredNow > 0) ...[
          IconNumber(
            Icons.remove_circle_outline,
            '${r.hidNow}',
            spoken: 'hid ${r.hidNow}',
          ),
          IconNumber(
            Icons.add_circle_outline,
            '${r.restoredNow}',
            spoken: 'restored ${r.restoredNow}',
          ),
        ],
      ],
    );
  }
}

/// Curfew on/off glyph plus its window, e.g. "[on] 23:00-05:00".
class CurfewValue extends StatelessWidget {
  const CurfewValue(this.record, {super.key});

  final EnforcementRecord record;

  @override
  Widget build(BuildContext context) {
    final window = record.curfewWindow;
    return Wrap(
      spacing: kGap / 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        GlyphIcon(
          curfewGlyph(record.curfewActive),
          spoken: switch (record.curfewActive) {
            true => 'curfew active',
            false => 'curfew inactive',
            null => 'curfew unknown',
          },
        ),
        if (window != null) Text(window, style: const TextStyle(color: kText)),
      ],
    );
  }
}

/// "1.8 km" or "766 m".
String _metres(double m) =>
    m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

/// "45 s" or "3 min".
String _seconds(int s) => s >= 60 ? '${s ~/ 60} min' : '$s s';

/// How long ago [at] was: "<1 min", "12 min", "3 h", "2 d".
String agoLabel(DateTime at, DateTime now) {
  final delta = now.difference(at);
  if (delta.inMinutes < 1) return '<1 min';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min';
  if (delta.inHours < 24) return '${delta.inHours} h';
  return '${delta.inDays} d';
}
