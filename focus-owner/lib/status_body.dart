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
          key: const Key('details-toggle'),
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
                      icon: Icons.admin_panel_settings,
                      semanticLabel: 'Device owner',
                      key: const Key('row-owner'),
                      value: _flag(status.isDeviceOwner, falseIsBad: true),
                    ),
                    if (policyError == null && policy != null)
                      _Row(
                        icon: Icons.fence,
                        semanticLabel: 'Geofence',
                        key: const Key('row-geofence'),
                        value: _geofenceFlag(hasHome),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.expand_less, color: kMuted),
            ],
          ),
        ),
        if (policyError != null)
          _policyFailed(policyError!)
        else if (policy == null)
          const LinearProgressIndicator(
            key: Key('policy-loading'),
            semanticsLabel: 'Policy loading',
          ),
        const SizedBox(height: kGap),
        _ActionGrid(
          children: [
            OutlinedButton(
              key: const Key('run-enforcement'),
              onPressed: busy ? null : onRunNow,
              child: const Icon(
                Icons.play_arrow,
                semanticLabel: 'Run enforcement now',
              ),
            ),
            if (status.isDeviceOwner) ...[
              OutlinedButton(
                key: const Key('set-home'),
                onPressed: busy ? null : onSetHome,
                child: Icon(
                  hasHome ? Icons.edit_location_alt : Icons.add_home,
                  color: hasHome ? null : kDanger,
                  semanticLabel: hasHome
                      ? 'Update home to here'
                      : 'Set home to current location',
                ),
              ),
              OutlinedButton(
                key: const Key('lock-vpn'),
                onPressed: busy ? null : onLockVpn,
                child: const Icon(
                  Icons.vpn_lock,
                  semanticLabel: 'Lock VPN configuration',
                ),
              ),
              FilledButton(
                key: const Key('release-owner'),
                onPressed: busy ? null : onRelease,
                style: FilledButton.styleFrom(backgroundColor: kDanger),
                child: const Icon(
                  Icons.lock_open,
                  semanticLabel: 'Release device owner',
                ),
              ),
            ],
          ],
        ),
        // "Not provisioned, nothing is enforced" was a sentence here; the
        // owner row's danger-coloured cross above now says it.
      ],
    );
  }
}

/// Yes/no as a check or cross, spoken as the old word.
Widget _flag(bool value, {bool falseIsBad = false}) => GlyphIcon(
  boolGlyph(value, falseIsBad: falseIsBad),
  spoken: value ? 'yes' : 'no',
  size: 22,
);

/// Whether the geofence applies. A cross in danger colour means no home is
/// set, so enforcement is permanent: the distinction must stay on screen.
Widget _geofenceFlag(bool hasHome) => GlyphIcon(
  boolGlyph(hasHome, falseIsBad: true),
  spoken: hasHome ? 'active' : 'no home set - enforcing everywhere',
  size: 22,
);

/// The policy asset failed to parse: a danger glyph pair, error spoken.
Widget _policyFailed(String error) => Semantics(
  label: 'Policy: $error',
  excludeSemantics: true,
  child: const Row(
    key: Key('policy-error'),
    children: [
      Icon(Icons.policy, color: kDanger),
      Icon(Icons.error, color: kDanger),
    ],
  ),
);

/// Formats minutes-since-midnight as HH:MM.
String _hhmm(int minutes) {
  final h = (minutes ~/ 60).toString().padLeft(2, '0');
  final m = (minutes % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.semanticLabel,
    required this.value,
    super.key,
  });

  final IconData icon;
  final String semanticLabel;

  /// The value: a glyph, or a Text holding a number or policy data.
  final Widget value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kGap / 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: kMuted, semanticLabel: semanticLabel),
          Flexible(child: value),
        ],
      ),
    );
  }
}

/// A number or policy value painted in the row's text style.
Widget _value(String text) => Text(
  text,
  style: const TextStyle(color: kText),
  textAlign: TextAlign.end,
);
