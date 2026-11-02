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
    required this.onRefreshLocation,
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

  /// Re-acquires a location fix; the card's location rows tap into it.
  final Future<void> Function() onRefreshLocation;

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
          record: EnforcementRecord.latestPass(log),
          onOpenLog: onOpenLog ?? () {},
          onRefreshLocation: busy ? null : onRefreshLocation,
        ),
        const SizedBox(height: kGap / 2),
        // The rows that decide whether the enforcer applies stay on screen (what it
        // last did is the card above);
        // the rest of the provisioning detail is one tap away in a sheet, so
        // this page fits one phone screen without scrolling.
        InkWell(
          onTap: () => _showDetailsSheet(
            context,
            status: status,
            policy: policy,
            policyError: policyError,
            log: log,
            hasHome: hasHome,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    _Row(
                      label: 'Device owner',
                      value: status.isDeviceOwner ? 'yes' : 'no',
                    ),
                    if (policyError == null && policy != null)
                      _Row(label: 'Geofence', value: _geofenceLabel(hasHome)),
                  ],
                ),
              ),
              const Icon(Icons.expand_less, color: kMuted),
            ],
          ),
        ),
        if (policyError != null)
          _Message(text: 'Policy: $policyError', color: kDanger)
        else if (policy == null)
          const _Message(text: 'Policy: loading...', color: kMuted),
        const SizedBox(height: kGap),
        _ActionGrid(
          children: [
            OutlinedButton(
              onPressed: busy ? null : onRunNow,
              child: const Text('Run enforcement now'),
            ),
            if (status.isDeviceOwner) ...[
              OutlinedButton(
                onPressed: busy ? null : onSetHome,
                child: Text(
                  hasHome
                      ? 'Update home to here'
                      : 'Set home to current location',
                ),
              ),
              OutlinedButton(
                onPressed: busy ? null : onLockVpn,
                child: const Text('Lock VPN configuration'),
              ),
              FilledButton(
                onPressed: busy ? null : onRelease,
                style: FilledButton.styleFrom(backgroundColor: kDanger),
                child: const Text('Release device owner'),
              ),
            ],
          ],
        ),
        if (!status.isDeviceOwner) ...[
          const SizedBox(height: kGap),
          const _Message(
            text: 'Not provisioned as device owner. Nothing is enforced.',
            color: kMuted,
          ),
        ],
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
