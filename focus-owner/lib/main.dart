import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:focus_owner/debug_log_page.dart';
import 'package:focus_owner/device_policy.dart';
import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/enforcement_status_card.dart';
import 'package:focus_owner/policy.dart';
import 'package:focus_owner/theme.dart';

part 'status_page_state.dart';

part 'status_page_dialogs.dart';

part 'status_body.dart';

void main() => runApp(const FocusOwnerApp());

// The palette used to be duplicated here as `kField`…`kDanger`, byte for
// byte identical to theme.dart's copy. Both are gone: theme.dart now aliases
// the shared design_system palette, and this file reads those aliases.

/// How often to re-read the log while waiting for a pass to land.
const Duration _kRefreshInterval = Duration(seconds: 2);

/// Gives up after this many polls, ~30 s — a little longer than the pass's own
/// location timeout, so a slow fix is waited out rather than reported stale.
const int _kRefreshAttempts = 15;

class FocusOwnerApp extends StatelessWidget {
  const FocusOwnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Focus Owner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kField,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          surface: kSurface,
          error: kDanger,
        ),
      ),
      home: const StatusPage(),
    );
  }
}

/// Shows provisioning state and offers the one action this build supports:
/// giving up device ownership.
class StatusPage extends StatefulWidget {
  const StatusPage({
    super.key,
    this.policy = const DevicePolicy(),
    this.loadFocusPolicy = FocusPolicy.load,
  });

  final DevicePolicy policy;

  /// Injectable so tests can supply a policy without a rootBundle asset.
  final Future<FocusPolicy> Function() loadFocusPolicy;

  @override
  State<StatusPage> createState() => _StatusPageState();
}
