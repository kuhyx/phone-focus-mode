/// The status page's detail sheet and action grid.
///
/// Split out of status_body.dart to keep it under the 250-line cap. A `part`
/// because the row widgets it reuses are library-private.

part of 'main.dart';

/// "Enforcing" row value: how many apps the last recorded pass hid, or an
/// empty hourglass when no pass exists yet.
Widget _enforcingValue(List<EnforcementRecord> log) =>
    switch (EnforcementRecord.latestPass(log)?.hideCount) {
      null => const Icon(
        Icons.hourglass_empty,
        color: kMuted,
        semanticLabel: 'no pass recorded yet',
      ),
      final int n => IconNumber(
        Icons.visibility_off,
        '$n',
        spoken: '$n apps hidden',
      ),
    };

/// Lays [children] out two per row, each pair a fixed-height row.
class _ActionGrid extends StatelessWidget {
  const _ActionGrid({required this.children});

  final List<Widget> children;

  static const double _tileHeight = 56;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: kGap / 2));
      rows.add(
        SizedBox(
          height: _tileHeight,
          child: Row(
            children: [
              Expanded(child: children[i]),
              const SizedBox(width: kGap / 2),
              Expanded(
                child: i + 1 < children.length
                    ? children[i + 1]
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }
}

/// Opens every provisioning and policy row, which the page itself shows only
/// in part.
Future<void> _showDetailsSheet(
  BuildContext context, {
  required DevicePolicyStatus status,
  required FocusPolicy? policy,
  required String? policyError,
  required List<EnforcementRecord> log,
  required bool hasHome,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kSurface,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(kGap),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Row(
              key: const Key('detail-package'),
              icon: Icons.inventory_2,
              semanticLabel: 'Package',
              // The package id is the app's identifier, not prose.
              value: _value(status.packageName),
            ),
            _Row(
              icon: Icons.admin_panel_settings,
              semanticLabel: 'Device owner',
              value: _flag(status.isDeviceOwner, falseIsBad: true),
            ),
            _Row(
              icon: Icons.verified_user,
              semanticLabel: 'Admin active',
              value: _flag(status.isAdminActive),
            ),
            _Row(
              icon: Icons.android,
              semanticLabel: 'Android SDK',
              value: _value('${status.sdkInt}'),
            ),
            _Row(
              icon: Icons.shield,
              semanticLabel: 'Enforcing',
              value: _enforcingValue(log),
            ),
            if (policyError != null)
              _policyFailed(policyError)
            else if (policy != null) ...[
              _Row(
                key: const Key('detail-allowed-apps'),
                icon: Icons.apps,
                semanticLabel: 'Allowed apps',
                value: Wrap(
                  children: [
                    IconNumber(
                      Icons.wb_sunny,
                      '${policy.allowedPackages.length}',
                      spoken: '${policy.allowedPackages.length} allowed',
                    ),
                    IconNumber(
                      Icons.bedtime,
                      '${policy.nightAllowedPackages.length}',
                      spoken: '${policy.nightAllowedPackages.length} at night',
                    ),
                  ],
                ),
              ),
              _Row(
                icon: Icons.bedtime,
                semanticLabel: 'Curfew',
                value: policy.curfew == null
                    ? GlyphIcon(curfewGlyph(false), spoken: 'disabled')
                    : _value(
                        '${_hhmm(policy.curfew!.startMinutes)}'
                        '-${_hhmm(policy.curfew!.endMinutes)}',
                      ),
              ),
              _Row(
                icon: Icons.radar,
                semanticLabel: 'Home radius',
                value: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (!policy.home.hasCoordinates)
                      const Icon(
                        Icons.location_off,
                        size: 16,
                        color: kMuted,
                        semanticLabel: 'coords redacted',
                      ),
                    _value(' ${policy.home.radiusM.round()} m'),
                  ],
                ),
              ),
              _Row(
                key: const Key('detail-workout-domains'),
                icon: Icons.fitness_center,
                semanticLabel: 'Workout domains',
                value: _value('${policy.workoutUnblockDomains.length}'),
              ),
              _Row(
                icon: Icons.fence,
                semanticLabel: 'Geofence',
                value: _geofenceFlag(hasHome),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
