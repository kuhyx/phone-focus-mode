/// The two sync controls in the status page's app bar: Google sign-in and
/// the end-to-end passphrase (wake-alarm phone_app's lock button).
///
/// Set once per install. Every successful sign-in or passphrase save pushes
/// one harmless `install_check`, so the icon shows whether focus-owner can
/// publish at all before WakeAlarm ever goes missing.
library;

import 'dart:async';

import 'package:crdt_sync_flutter/crdt_sync_flutter.dart'
    show E2ePassphraseButton;
import 'package:material_ui/material_ui.dart';
import 'package:focus_owner/sync/backend.dart';
import 'package:focus_owner/sync/publish.dart';
import 'package:focus_owner/theme.dart';

/// Sign-in + passphrase, with the last publish check as the icon state.
class SyncActions extends StatefulWidget {
  /// Creates the controls.
  const SyncActions({super.key});

  @override
  State<SyncActions> createState() => _SyncActionsState();
}

class _SyncActionsState extends State<SyncActions> {
  /// Null until a check ran this session; then whether it reached Firebase.
  bool? _published;
  bool _busy = false;

  Future<void> _check() async {
    final ok = await publishInstallCheck();
    if (mounted) setState(() => _published = ok);
  }

  Future<void> _signIn() async {
    setState(() => _busy = true);
    try {
      await signInWithGoogle();
    } on Object catch (e) {
      debugPrint('FocusOwnerSync: sign-in failed: $e');
    }
    await _check();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      E2ePassphraseButton(
        key: const Key('sync-passphrase'),
        locked: _published != true,
        onSaved: () => unawaited(_check()),
      ),
      Tooltip(
        message: 'Sync',
        child: IconButton(
          key: const Key('sync-sign-in'),
          onPressed: _busy || !googleSignInSupported
              ? null
              : () => unawaited(_signIn()),
          icon: Icon(
            switch (_published) {
              true => Icons.cloud_done,
              false => Icons.cloud_off,
              null => Icons.cloud_outlined,
            },
            color: _published == false ? kDanger : null,
            semanticLabel: 'Sync',
          ),
        ),
      ),
    ],
  );
}
