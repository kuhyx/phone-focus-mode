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
  required bool hasHome,
  required List<EnforcementRecord> log,
  required VoidCallback onOpenLog,
}) {
  if (error != null) {
    return const _Message(text: 'Could not read state', color: kDanger);
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
    title: const Text('Lock VPN configuration?'),
    content: const Text(
      'The always-on VPN can no longer be turned off from Settings. '
      'Releasing device owner lifts this.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Lock'),
      ),
    ],
  );
}

Widget _releaseDialog(BuildContext context, {required bool hasAccounts}) {
  return AlertDialog(
    backgroundColor: kSurface,
    title: const Text('Release device owner?'),
    // Deliberately concrete, and honest in both directions. "Restored only
    // by a factory reset" is true but abstract, and this dialog is read in
    // the moment the block is most inconvenient -- the price has to be
    // legible right then, not inferred. While no account exists the price
    // really is low, and overstating it there would teach the user to
    // ignore the warning that matters later.
    content: Text(
      hasAccounts
          ? 'Enforcement stops. YouTube comes back.\n\n'
                'Accounts exist on this device, so device owner can NEVER '
                'be set again without a factory reset. That means '
                're-pairing mBank, Revolut and inFakt over SMS, '
                're-activating mObywatel, signing in to every account '
                'again, and losing Signal history.\n\n'
                'This is the way out if something is broken. It is a bad '
                'trade for wanting to watch a video.'
          : 'Enforcement stops and YouTube comes back.\n\n'
                'No account exists yet, so device owner can be set again '
                'straight afterwards without a wipe. This is the moment to '
                'test the release path, before signing in.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, true),
        style: TextButton.styleFrom(foregroundColor: kDanger),
        child: const Text('Release'),
      ),
    ],
  );
}
