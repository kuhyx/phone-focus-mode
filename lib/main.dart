import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:focus_owner/debug_log_page.dart';
import 'package:focus_owner/device_policy.dart';
import 'package:focus_owner/enforcement_record.dart';
import 'package:focus_owner/enforcement_status_card.dart';
import 'package:focus_owner/policy.dart';

void main() => runApp(const FocusOwnerApp());

/// Shared palette: charcoal field with a single accent, matching the other
/// com.kuhy.* apps.
const Color _kField = Color(0xFF1B1D21);
const Color _kSurface = Color(0xFF24272C);
const Color _kAccent = Color(0xFF5B9DD9);
const Color _kText = Color(0xFFE8EAED);
const Color _kMuted = Color(0xFF9AA0A6);
const Color _kDanger = Color(0xFFD9776B);

const double _kGap = 16;

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
        scaffoldBackgroundColor: _kField,
        colorScheme: const ColorScheme.dark(
          primary: _kAccent,
          surface: _kSurface,
          error: _kDanger,
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

class _StatusPageState extends State<StatusPage> {
  DevicePolicyStatus? _status;
  FocusPolicy? _focusPolicy;
  String? _policyError;
  String? _error;
  bool _busy = false;
  bool _hasHome = false;
  List<EnforcementRecord> _log = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      await Future.wait([_loadDeviceStatus(), _loadPolicy(), _loadLog()]);
    } finally {
      // In a finally because _busy gates the release-device-owner button. If
      // any loader throws -- a malformed log record used to be enough -- the
      // flag would stay true for the life of the process, and since _refresh
      // runs from initState that means the escape hatch is dead on every
      // launch. Diagnostics failing must never disable the way out.
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reads the durable record of past passes.
  ///
  /// Failing to read it must not blank the rest of the screen: the log is
  /// diagnostics, while the provisioning state above it is what the user needs
  /// to reach the escape hatch.
  Future<void> _loadLog() async {
    try {
      final lines = await widget.policy.readEnforcementLog();
      if (!mounted) return;
      setState(() => _log = EnforcementRecord.parseLines(lines));
    } on PlatformException {
      if (!mounted) return;
      setState(() => _log = const []);
    }
  }

  Future<void> _loadDeviceStatus() async {
    try {
      final status = await widget.policy.status();
      final hasHome = await widget.policy.hasHomeLocation();
      if (!mounted) return;
      setState(() {
        _status = status;
        _hasHome = hasHome;
        _error = null;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message ?? 'Could not read device policy state');
    }
  }

  Future<void> _loadPolicy() async {
    try {
      final policy = await widget.loadFocusPolicy();
      if (!mounted) return;
      setState(() {
        _focusPolicy = policy;
        _policyError = null;
      });
    } on PolicyFormatException catch (e) {
      // A policy that cannot be parsed must be reported, never silently
      // treated as an empty allowlist - that would block everything.
      if (!mounted) return;
      setState(() => _policyError = e.message);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _policyError = '$e');
    }
  }

  Future<void> _runNow() async {
    setState(() => _busy = true);
    final started = await widget.policy.runEnforcementNow();
    if (started) await _awaitNewRecord();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          started
              ? 'Enforcement run finished'
              : 'Could not start enforcement',
        ),
      ),
    );
  }

  /// Waits for the pass to append a record, then shows it.
  ///
  /// `runEnforcementNow` only *starts* the service, and a pass now waits up to
  /// [EnforcementRunner.ACQUIRE_TIMEOUT_MS] for a location fix, so re-reading
  /// immediately returns the record from the PREVIOUS pass. That is not a
  /// cosmetic lag: after re-anchoring home the screen kept showing the old
  /// distance, which reads as "the button did nothing" at exactly the moment
  /// the user is checking whether it worked.
  ///
  /// Polls rather than waits for a callback because the pass runs in a
  /// separate service process with no channel back to the UI.
  Future<void> _awaitNewRecord() async {
    final before = _log.isEmpty ? null : _log.first.timestamp;
    for (var attempt = 0; attempt < _kRefreshAttempts; attempt++) {
      await Future<void>.delayed(_kRefreshInterval);
      if (!mounted) return;
      await _loadLog();
      if (!mounted) return;
      final latest = _log.isEmpty ? null : _log.first.timestamp;
      if (latest != null && latest != before) break;
    }
    // Provisioning rows (home set / hidden counts) move with the pass too.
    await _loadDeviceStatus();
  }

  Future<void> _setHome() async {
    setState(() => _busy = true);
    final failure = await widget.policy.setHomeToCurrentLocation();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failure ??
              'Home set. Enforcement now applies here, not everywhere.',
        ),
      ),
    );
    if (failure != null) {
      await _refresh();
      return;
    }
    // Re-evaluate rather than only re-reading. The stored record still
    // describes the OLD home, so refreshing alone leaves the previous
    // distance on screen -- measured: after re-anchoring home the card still
    // read "AWAY, 766 m" until a pass ran, which looks like the button
    // failed. A new home is exactly when the geofence answer changes.
    setState(() => _busy = true);
    if (await widget.policy.runEnforcementNow()) await _awaitNewRecord();
    if (!mounted) return;
    setState(() => _busy = false);
    await _refresh();
  }

  Future<void> _lockVpn() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _kSurface,
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
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    final ok = await widget.policy.setVpnConfigBlocked(blocked: true);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'VPN configuration locked' : 'Could not lock - see logcat'),
      ),
    );
    await _refresh();
  }

  Future<void> _release() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _kSurface,
        title: const Text('Release device owner?'),
        // Deliberately concrete, and honest in both directions. "Restored only
        // by a factory reset" is true but abstract, and this dialog is read in
        // the moment the block is most inconvenient -- the price has to be
        // legible right then, not inferred. While no account exists the price
        // really is low, and overstating it there would teach the user to
        // ignore the warning that matters later.
        content: Text(
          _status?.hasAccounts ?? true
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
            style: TextButton.styleFrom(foregroundColor: _kDanger),
            child: const Text('Release'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    final released = await widget.policy.releaseDeviceOwner();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          released ? 'Device owner released' : 'Release failed - see logcat',
        ),
      ),
    );
    await _refresh();
  }

  void _openLog() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DebugLogPage(records: _log),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final error = _error;
    final Widget body;
    if (error != null) {
      body = const _Message(text: 'Could not read state', color: _kDanger);
    } else if (status != null) {
      body = _StatusBody(
        status: status,
        focusPolicy: _focusPolicy,
        policyError: _policyError,
        busy: _busy,
        onRelease: _release,
        onRunNow: _runNow,
        onSetHome: _setHome,
        onLockVpn: _lockVpn,
        hasHome: _hasHome,
        log: _log,
        onOpenLog: _openLog,
      );
    } else {
      body = const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: _kField,
        foregroundColor: _kText,
        title: const Text('Focus Owner'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      // Scrollable because the action list grew past a short screen: an
      // unreachable "Release device owner" button is the one control that
      // must never be clipped off the bottom.
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(_kGap),
        child: body,
      ),
    );
  }
}

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
        const SizedBox(height: _kGap),
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
        const SizedBox(height: _kGap),
        const Divider(color: _kMuted),
        const SizedBox(height: _kGap / 2),
        if (policyError != null)
          _Message(text: 'Policy: $policyError', color: _kDanger)
        else if (policy == null)
          const _Message(text: 'Policy: loading...', color: _kMuted)
        else ...[
          _Row(
            label: 'Allowed apps',
            value: '${policy.allowedPackages.length}'
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
        const SizedBox(height: _kGap * 2),
        OutlinedButton(
          onPressed: busy ? null : onRunNow,
          child: const Text('Run enforcement now'),
        ),
        const SizedBox(height: _kGap),
        if (status.isDeviceOwner) ...[
          OutlinedButton(
            onPressed: busy ? null : onSetHome,
            child: Text(
              hasHome ? 'Update home to here' : 'Set home to current location',
            ),
          ),
          const SizedBox(height: _kGap),
          OutlinedButton(
            onPressed: busy ? null : onLockVpn,
            child: const Text('Lock VPN configuration'),
          ),
          const SizedBox(height: _kGap),
        ],
        if (status.isDeviceOwner)
          FilledButton(
            onPressed: busy ? null : onRelease,
            style: FilledButton.styleFrom(backgroundColor: _kDanger),
            child: const Text('Release device owner'),
          )
        else
          const _Message(
            text: 'Not provisioned as device owner. Nothing is enforced.',
            color: _kMuted,
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
      padding: const EdgeInsets.symmetric(vertical: _kGap / 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: _kMuted)),
          Text(value, style: const TextStyle(color: _kText)),
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
