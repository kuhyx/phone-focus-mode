/// Confirmation dialogs and the body-selection helper for the StatusPage.
///
/// Split out of status_page_state.dart to keep it under the 250-line cap. A
/// `part` because these builders are library-private, same as the rest of
/// the StatusPage split.

part of 'main.dart';

/// Picks the StatusPage's body widget for the current load state.
Widget _statusPageBody({
  required DevicePolicyStatus? status,
  required String? error,
  required FocusPolicy? focusPolicy,
  required String? policyError,
  required bool busy,
  required Future<void> Function() onRelease,
  required Future<void> Function() onRunNow,
  required Future<void> Function() onSetHome,
  required Future<void> Function() onLockVpn,
  required Future<void> Function() onRefreshLocation,
  required bool hasHome,
  required List<EnforcementRecord> log,
  required VoidCallback onOpenLog,
}) {
  if (error != null) {
    return const Center(
      child: Icon(
        Icons.error_outline,
        key: Key('state-error'),
        size: 48,
        color: kDanger,
        semanticLabel: 'Could not read state',
      ),
    );
  }
  if (status != null) {
    return _StatusBody(
      status: status,
      focusPolicy: focusPolicy,
      policyError: policyError,
      busy: busy,
      onRelease: onRelease,
      onRunNow: onRunNow,
      onSetHome: onSetHome,
      onLockVpn: onLockVpn,
      onRefreshLocation: onRefreshLocation,
      hasHome: hasHome,
      log: log,
      onOpenLog: onOpenLog,
    );
  }
  return const Center(child: CircularProgressIndicator());
}

Widget _lockVpnDialog(BuildContext context) {
  return AlertDialog(
    backgroundColor: kSurface,
    title: const Icon(Icons.vpn_lock, size: 48),
    actions: [
      IconButton(
        key: const Key('vpn-cancel'),
        icon: const Icon(Icons.close, semanticLabel: 'Cancel'),
        onPressed: () => Navigator.pop(context, false),
      ),
      IconButton(
        key: const Key('vpn-confirm'),
        icon: const Icon(Icons.check, semanticLabel: 'Lock'),
        onPressed: () => Navigator.pop(context, true),
      ),
    ],
  );
}

Widget _releaseDialog(BuildContext context, {required bool hasAccounts}) {
  return AlertDialog(
    key: const Key('release-dialog'),
    backgroundColor: kSurface,
    title: const Icon(Icons.lock_open, size: 48),
    // The price of releasing, as a picture. With accounts on the device,
    // device owner only comes back after a factory reset (danger-coloured
    // phone-erase glyph); without, it can be set again straight away (replay
    // glyph). The full sentence is the spoken label.
    content: hasAccounts
        ? const Icon(
            Icons.phonelink_erase,
            key: Key('release-price-wipe'),
            size: 40,
            color: kDanger,
            semanticLabel:
                'Accounts exist, so device owner can never be set again '
                'without a factory reset',
          )
        : const Icon(
            Icons.replay,
            key: Key('release-price-free'),
            size: 40,
            color: kAccent,
            semanticLabel:
                'No account exists yet, so device owner can be set again '
                'without a wipe',
          ),
    actions: [
      IconButton(
        key: const Key('release-cancel'),
        icon: const Icon(Icons.close, semanticLabel: 'Cancel'),
        onPressed: () => Navigator.pop(context, false),
      ),
      IconButton(
        key: const Key('release-confirm'),
        icon: const Icon(Icons.check, color: kDanger, semanticLabel: 'Release'),
        onPressed: () => Navigator.pop(context, true),
      ),
    ],
  );
}
