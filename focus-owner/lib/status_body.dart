/// The status page body and its sub-widgets.
///
/// Split out of main.dart to keep it under the 250-line cap. A `part`
/// because Dart privates are library-scoped and these widgets are private.

part of 'main.dart';

class _StatusBody extends StatelessWidget {
  const _StatusBody({
    required this.status,
    required this.focusPolicy,
    required this.policyError,
    required this.busy,
    required this.onRelease,
    required this.onRunNow,
    required this.onSetHome,
    required this.onLockVpn,
    required this.hasHome,
    this.log = const [],
    this.onOpenLog,
  });

  final DevicePolicyStatus status;
  final FocusPolicy? focusPolicy;
  final String? policyError;
  final bool busy;
  final Future<void> Function() onRelease;
  final Future<void> Function() onRunNow;
  final Future<void> Function() onSetHome;
  final Future<void> Function() onLockVpn;

  /// Whether home coordinates exist; without them enforcement is permanent.
  final bool hasHome;

  /// Recorded passes, newest first.
  final List<EnforcementRecord> log;
  final VoidCallback? onOpenLog;

  @override
  Widget build(BuildContext context) {
    final policy = focusPolicy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // First, and largest: what the enforcer is doing right now and why.
        // Everything below is provisioning detail that only matters once this
        // question is answered.
        EnforcementStatusCard(
          record: log.isEmpty ? null : log.first,
          onOpenLog: onOpenLog ?? () {},
        ),
        const SizedBox(height: kGap),
        _Row(label: 'Package', value: status.packageName),
        _Row(label: 'Device owner', value: status.isDeviceOwner ? 'yes' : 'no'),
        _Row(label: 'Admin active', value: status.isAdminActive ? 'yes' : 'no'),
        _Row(label: 'Android SDK', value: '${status.sdkInt}'),
        // "none (inert build)" was a leftover from when this app really did
        // apply nothing. It has been enforcing for weeks, so the honest value
        // is whether the last recorded pass hid anything.
        _Row(
          label: 'Enforcing',
          value: switch (log.isEmpty ? null : log.first.hideCount) {
            null => 'no pass recorded yet',
            0 => 'nothing hidden',
            final int n => '$n apps hidden',
          },
        ),
        const SizedBox(height: kGap),
        const Divider(color: kMuted),
        const SizedBox(height: kGap / 2),
        if (policyError != null)
          _Message(text: 'Policy: $policyError', color: kDanger)
        else if (policy == null)
          const _Message(text: 'Policy: loading...', color: kMuted)
        else ...[
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
          // The distinction that decides whether enforcement is geofenced or
          // permanent, so it belongs on screen rather than only in logcat.
          _Row(
            label: 'Geofence',
            value: hasHome ? 'active' : 'no home set - enforcing everywhere',
          ),
        ],
        const SizedBox(height: kGap * 2),
        OutlinedButton(
          onPressed: busy ? null : onRunNow,
          child: const Text('Run enforcement now'),
        ),
        const SizedBox(height: kGap),
        if (status.isDeviceOwner) ...[
          OutlinedButton(
            onPressed: busy ? null : onSetHome,
            child: Text(
              hasHome ? 'Update home to here' : 'Set home to current location',
            ),
          ),
          const SizedBox(height: kGap),
          OutlinedButton(
            onPressed: busy ? null : onLockVpn,
            child: const Text('Lock VPN configuration'),
          ),
          const SizedBox(height: kGap),
        ],
        if (status.isDeviceOwner)
          FilledButton(
            onPressed: busy ? null : onRelease,
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            child: const Text('Release device owner'),
          )
        else
          const _Message(
            text: 'Not provisioned as device owner. Nothing is enforced.',
            color: kMuted,
          ),
      ],
    );
  }
}

/// Formats minutes-since-midnight as HH:MM.
String _hhmm(int minutes) {
  final h = (minutes ~/ 60).toString().padLeft(2, '0');
  final m = (minutes % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kGap / 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: kMuted)),
          Text(value, style: const TextStyle(color: kText)),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(color: color));
}
