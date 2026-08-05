import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:focus_owner/device_policy.dart';

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
  const StatusPage({super.key, this.policy = const DevicePolicy()});

  final DevicePolicy policy;

  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  DevicePolicyStatus? _status;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final status = await widget.policy.status();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message ?? 'Could not read device policy state');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _release() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _kSurface,
        title: const Text('Release device owner?'),
        content: const Text(
          'The app will give up device ownership. Enforcement stops and '
          'ownership can only be restored by a factory reset.',
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

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final error = _error;
    final Widget body;
    if (error != null) {
      body = const _Message(text: 'Could not read state', color: _kDanger);
    } else if (status != null) {
      body = _StatusBody(status: status, busy: _busy, onRelease: _release);
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
      body: Padding(padding: const EdgeInsets.all(_kGap), child: body),
    );
  }
}

class _StatusBody extends StatelessWidget {
  const _StatusBody({
    required this.status,
    required this.busy,
    required this.onRelease,
  });

  final DevicePolicyStatus status;
  final bool busy;
  final Future<void> Function() onRelease;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Row(label: 'Package', value: status.packageName),
        _Row(label: 'Device owner', value: status.isDeviceOwner ? 'yes' : 'no'),
        _Row(label: 'Admin active', value: status.isAdminActive ? 'yes' : 'no'),
        _Row(label: 'Android SDK', value: '${status.sdkInt}'),
        _Row(
          label: 'Restrictions',
          value: status.restrictionsApplied ? 'applied' : 'none (inert build)',
        ),
        const SizedBox(height: _kGap * 2),
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
