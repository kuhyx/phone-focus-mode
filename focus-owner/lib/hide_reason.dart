// Split out of enforcement_record.dart for the 250-line cap; that file
// re-exports it, so no import changed.

/// Why a package is hidden, mirroring Kotlin's `HideReason`.
enum HideReason {
  alwaysBlocked,
  notInAllowlist,
  notInNightAllowlist,
  notInLockdownAllowlist,
  unknown;

  static HideReason parse(String? raw) => switch (raw) {
    'ALWAYS_BLOCKED' => HideReason.alwaysBlocked,
    'NOT_IN_ALLOWLIST' => HideReason.notInAllowlist,
    'NOT_IN_NIGHT_ALLOWLIST' => HideReason.notInNightAllowlist,
    'NOT_IN_LOCKDOWN_ALLOWLIST' => HideReason.notInLockdownAllowlist,
    _ => HideReason.unknown,
  };

  /// Plain-English explanation shown next to a hidden app.
  String get explanation => switch (this) {
    HideReason.alwaysBlocked => 'always blocked, everywhere',
    HideReason.notInAllowlist => 'not on the day allowlist',
    HideReason.notInNightAllowlist => 'not on the curfew allowlist',
    HideReason.notInLockdownAllowlist => 'not on the lockdown allowlist',
    HideReason.unknown => 'reason not recorded',
  };
}
