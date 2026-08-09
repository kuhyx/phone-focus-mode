import 'dart:math' as math;

import 'package:focus_owner/policy.dart';

/// Why enforcement is currently on or off.
///
/// Carried alongside the decision so the UI and the logs can say *why* an app
/// is hidden. "Blocked" with no reason is the kind of thing that makes a
/// wellbeing tool feel broken rather than deliberate.
enum EnforcementReason {
  /// Away from home, so nothing is enforced.
  away,

  /// At home during the day: the full allowlist applies.
  atHome,

  /// Inside the curfew window: the much shorter night allowlist applies.
  curfew,

  /// A workout is in progress, so the workout exceptions are released.
  workout,

  /// Location is unknown. Treated as "at home" deliberately — see
  /// [EnforcementDecision.evaluate].
  locationUnknown,
}

/// Inputs to one enforcement decision.
///
/// Grouped into a value type so the decision is a pure function of its inputs
/// and can be tested without a device, a clock, or a location provider.
class EnforcementInputs {
  const EnforcementInputs({
    required this.installedPackages,
    required this.minutesSinceMidnight,
    this.latitude,
    this.longitude,
    this.currentlyEnforcing = false,
    this.workoutActive = false,
  });

  /// Third-party packages present on the device.
  final Set<String> installedPackages;

  /// Local time, as minutes since midnight.
  final int minutesSinceMidnight;

  /// Current position, or null when location is unavailable.
  final double? latitude;
  final double? longitude;

  /// Whether enforcement is already active, for geofence hysteresis.
  final bool currentlyEnforcing;

  /// Whether a workout is in progress.
  final bool workoutActive;
}

/// The outcome of evaluating the policy against the current conditions.
class EnforcementDecision {
  const EnforcementDecision({
    required this.reason,
    required this.packagesToHide,
    required this.packagesToShow,
  });

  /// Decides which packages should be hidden right now.
  ///
  /// Fail-closed on unknown location, matching `focus_daemon.sh`, which logs
  /// "Location unavailable - defaulting to focus mode". Losing GPS must not be
  /// a way to switch enforcement off.
  ///
  /// Note the asymmetry that makes this safe to run unattended: every package
  /// the policy allows appears in [packagesToShow] on *every* evaluation, not
  /// only on transitions. A missed run therefore leaves apps hidden that
  /// should be visible only until the next run, and the next run repairs it
  /// without needing to know what the previous one did.
  factory EnforcementDecision.evaluate(
    FocusPolicy policy,
    EnforcementInputs inputs,
  ) {
    final hasFix = inputs.latitude != null && inputs.longitude != null;
    final atHome = hasFix &&
        _isInside(
          policy,
          inputs.latitude!,
          inputs.longitude!,
          currentlyEnforcing: inputs.currentlyEnforcing,
        );

    if (hasFix && !atHome) {
      return EnforcementDecision(
        reason: EnforcementReason.away,
        packagesToHide: const {},
        packagesToShow: inputs.installedPackages,
      );
    }

    final duringCurfew = policy.isCurfewActive(inputs.minutesSinceMidnight);
    final reason = !hasFix
        ? EnforcementReason.locationUnknown
        : duringCurfew
            ? EnforcementReason.curfew
            : EnforcementReason.atHome;

    final hide = <String>{};
    final show = <String>{};
    for (final package in inputs.installedPackages) {
      if (policy.isAllowed(package, duringCurfew: duringCurfew)) {
        show.add(package);
      } else {
        hide.add(package);
      }
    }

    if (inputs.workoutActive) {
      // A workout releases its exception apps from whatever the current
      // state would otherwise be, without disturbing anything else.
      for (final package in policy.workoutExemptPackages) {
        if (hide.remove(package)) show.add(package);
      }
      return EnforcementDecision(
        reason: EnforcementReason.workout,
        packagesToHide: hide,
        packagesToShow: show,
      );
    }

    return EnforcementDecision(
      reason: reason,
      packagesToHide: hide,
      packagesToShow: show,
    );
  }

  /// Why this decision was reached.
  final EnforcementReason reason;

  /// Packages that must be hidden.
  final Set<String> packagesToHide;

  /// Packages that must be visible.
  ///
  /// Always the complete allowed set, never a delta. Unhiding is the failure
  /// mode that matters: a system that fails to hide is a mild disappointment,
  /// one that fails to unhide strands the user without a dialer or a bank.
  final Set<String> packagesToShow;

  /// Whether anything is currently restricted.
  bool get isEnforcing => packagesToHide.isNotEmpty;

  static bool _isInside(
    FocusPolicy policy,
    double latitude,
    double longitude, {
    required bool currentlyEnforcing,
  }) {
    final home = policy.home;
    if (!home.hasCoordinates) {
      // No coordinates configured: the geofence cannot be evaluated, so it
      // must not silently pass. Treated as "at home" by the caller via the
      // hasFix path above; here we simply refuse to claim the user is away.
      return true;
    }
    final metres = _haversineMetres(
      home.latitude!,
      home.longitude!,
      latitude,
      longitude,
    );
    final threshold = home.radiusM + (currentlyEnforcing ? home.hysteresisM : 0);
    return metres <= threshold;
  }

  static double _haversineMetres(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusM = 6371000.0;
    final dLat = _radians(lat2 - lat1);
    final dLon = _radians(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_radians(lat1)) *
            math.cos(_radians(lat2)) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * earthRadiusM * math.asin(math.sqrt(a.toDouble()));
  }

  static double _radians(double degrees) => degrees * math.pi / 180.0;
}
