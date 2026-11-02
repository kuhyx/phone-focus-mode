/// The status page's detail sheet and action grid.
///
/// Split out of status_body.dart to keep it under the 250-line cap. A `part`
/// because the row widgets it reuses are library-private.

part of 'main.dart';

/// "Enforcing" row value: what the last recorded pass hid.
///
/// "none (inert build)" was a leftover from when this app really did apply
/// nothing. It has been enforcing for weeks, so the honest value is whether
/// the last recorded pass hid anything.
String _enforcingLabel(List<EnforcementRecord> log) =>
    switch (EnforcementRecord.latestPass(log)?.hideCount) {
      null => 'no pass recorded yet',
      0 => 'nothing hidden',
      final int n => '$n apps hidden',
    };

/// The distinction that decides whether enforcement is geofenced or
/// permanent, so it belongs on screen rather than only in logcat.
String _geofenceLabel(bool hasHome) =>
    hasHome ? 'active' : 'no home set - enforcing everywhere';

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
            _Row(label: 'Package', value: status.packageName),
            _Row(
              label: 'Device owner',
              value: status.isDeviceOwner ? 'yes' : 'no',
            ),
            _Row(
              label: 'Admin active',
              value: status.isAdminActive ? 'yes' : 'no',
            ),
            _Row(label: 'Android SDK', value: '${status.sdkInt}'),
            _Row(label: 'Enforcing', value: _enforcingLabel(log)),
            if (policyError != null)
              _Message(text: 'Policy: $policyError', color: kDanger)
            else if (policy != null) ...[
              _Row(
                label: 'Allowed apps',
                value:
                    '${policy.allowedPackages.length}'
                    ' (${policy.nightAllowedPackages.length} at night)',
              ),
              _Row(
                label: 'Curfew',
                value: policy.curfew == null
                    ? 'disabled'
                    : '${_hhmm(policy.curfew!.startMinutes)}'
                          '-${_hhmm(policy.curfew!.endMinutes)}',
              ),
              _Row(
                label: 'Home radius',
                value: policy.home.hasCoordinates
                    ? '${policy.home.radiusM.round()} m'
                    : '${policy.home.radiusM.round()} m (coords redacted)',
              ),
              _Row(
                label: 'Workout domains',
                value: '${policy.workoutUnblockDomains.length}',
              ),
              _Row(label: 'Geofence', value: _geofenceLabel(hasHome)),
            ],
          ],
        ),
      ),
    ),
  );
}
