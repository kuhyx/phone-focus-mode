/// Icon + colour for every enforcement state the app paints.
///
/// kuhy's textgate rule: nothing on screen carries a word. Each state that
/// used to be a sentence or an enum word is a [Glyph] here instead: a shape
/// and a colour, so no state relies on colour alone. The old wording stays
/// as the spoken label (see the `explanation` getters), never painted.
library;

import 'package:flutter/material.dart';

import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/theme.dart';

/// A state's picture: what is drawn and in which colour.
@immutable
class Glyph {
  const Glyph(this.icon, this.color);

  final IconData icon;
  final Color color;

  @override
  bool operator ==(Object other) =>
      other is Glyph && other.icon == icon && other.color == color;

  @override
  int get hashCode => Object.hash(icon, color);
}

/// The headline state of a record.
///
/// Danger colours mark the states that need attention, as the old headline
/// colours did: a failed pass, no home, no location fix.
Glyph reasonGlyph(EnforcementRecord r) {
  if (r.failure != null) return const Glyph(Icons.error, kDanger);
  if (r.homeMissing) return const Glyph(Icons.add_home, kDanger);
  return switch (r.reason) {
    'AWAY' => const Glyph(Icons.directions_walk, kMuted),
    'AT_HOME' => const Glyph(Icons.home, kAccent),
    'CURFEW' => const Glyph(Icons.bedtime, kWarn),
    'WORKOUT' => const Glyph(Icons.fitness_center, kAccent),
    'WORKDAY_LOCKDOWN' => const Glyph(Icons.lock_clock, kAccent),
    'LOCKDOWN_ACTIVATED' => const Glyph(Icons.lock_clock, kWarn),
    'LOCKDOWN_EXTENDED' => const Glyph(Icons.more_time, kWarn),
    'LOCKDOWN_UNCHANGED' => const Glyph(Icons.lock, kMuted),
    'LOCKDOWN_LIFTED' => const Glyph(Icons.lock_open, kAccent),
    'LOCATION_UNKNOWN' => const Glyph(Icons.location_disabled, kDanger),
    _ => const Glyph(Icons.help, kWarn),
  };
}

/// Why one package is hidden. Always-blocked stands out in danger colour.
Glyph hideReasonGlyph(HideReason reason) => switch (reason) {
  HideReason.alwaysBlocked => const Glyph(Icons.block, kDanger),
  HideReason.notInAllowlist => const Glyph(Icons.wb_sunny, kMuted),
  HideReason.notInNightAllowlist => const Glyph(Icons.bedtime, kMuted),
  HideReason.notInLockdownAllowlist => const Glyph(Icons.lock_clock, kMuted),
  HideReason.unknown => const Glyph(Icons.help, kWarn),
};

/// Which location provider answered; null for an unrecognised one.
IconData? providerIcon(String? provider) => switch (provider) {
  'gps' => Icons.satellite_alt,
  'network' => Icons.cell_tower,
  'fused' => Icons.merge_type,
  'passive' => Icons.history,
  _ => null,
};

/// How the location request went (Kotlin's `FixOutcome`).
Glyph? fixOutcomeGlyph(String? outcome) => switch (outcome) {
  'CACHED_FRESH' => const Glyph(Icons.cached, kMuted),
  'ACTIVE_OK' => const Glyph(Icons.check, kAccent),
  'TIMEOUT' => const Glyph(Icons.hourglass_bottom, kWarn),
  'NO_PERMISSION' => const Glyph(Icons.location_disabled, kDanger),
  'NO_PROVIDER' => const Glyph(Icons.gps_off, kDanger),
  null => null,
  _ => const Glyph(Icons.help, kWarn),
};

/// Yes / no / not known. [falseIsBad] paints "no" in danger colour, for the
/// flags where "no" means nothing is enforced.
Glyph boolGlyph(bool? value, {bool falseIsBad = false}) => switch (value) {
  true => const Glyph(Icons.check_circle, kAccent),
  false => Glyph(Icons.cancel, falseIsBad ? kDanger : kMuted),
  null => const Glyph(Icons.help, kWarn),
};

/// Curfew on (warn), off (muted) or not known.
Glyph curfewGlyph(bool? active) => switch (active) {
  true => const Glyph(Icons.toggle_on, kWarn),
  false => const Glyph(Icons.toggle_off, kMuted),
  null => const Glyph(Icons.help, kWarn),
};
