/// The StatusPage state: polling, refresh and the device-status loads.
///
/// Split out of main.dart to keep it under the 250-line cap. A `part`
/// because the class and its fields are library-private.

part of 'main.dart';

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
      setState(
        () => _error = e.message ?? 'Could not read device policy state',
      );
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
          started ? 'Enforcement run finished' : 'Could not start enforcement',
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
          failure ?? 'Home set. Enforcement now applies here, not everywhere.',
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
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    final ok = await widget.policy.setVpnConfigBlocked(blocked: true);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'VPN configuration locked' : 'Could not lock - see logcat',
        ),
      ),
    );
    await _refresh();
  }

  Future<void> _release() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kSurface,
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
            style: TextButton.styleFrom(foregroundColor: kDanger),
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
        MaterialPageRoute<void>(builder: (_) => DebugLogPage(records: _log)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final error = _error;
    final Widget body;
    if (error != null) {
      body = const _Message(text: 'Could not read state', color: kDanger);
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
        backgroundColor: kField,
        foregroundColor: kText,
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
        padding: const EdgeInsets.all(kGap),
        child: body,
      ),
    );
  }
}
