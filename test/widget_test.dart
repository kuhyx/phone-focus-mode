import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/device_policy.dart';
import 'package:focus_owner/main.dart';

/// Builds a channel whose handler answers from [responses], recording calls.
({MethodChannel channel, List<MethodCall> calls}) _fakeChannel(
  Map<String, Object?> responses,
) {
  const channel = MethodChannel('test/device_policy');
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    if (!responses.containsKey(call.method)) {
      throw PlatformException(code: 'unimplemented', message: 'no stub');
    }
    return responses[call.method];
  });
  return (channel: channel, calls: calls);
}

Map<String, Object?> _statusMap({bool isDeviceOwner = false}) => {
      'packageName': 'com.kuhy.focus_owner',
      'isDeviceOwner': isDeviceOwner,
      'isAdminActive': isDeviceOwner,
      'sdkInt': 36,
      'restrictionsApplied': false,
    };

void main() {
  group('DevicePolicyStatus', () {
    test('parses the native status map', () {
      final status = DevicePolicyStatus.fromMap(_statusMap(isDeviceOwner: true));
      expect(status.packageName, 'com.kuhy.focus_owner');
      expect(status.isDeviceOwner, isTrue);
      expect(status.sdkInt, 36);
    });

    test('this build never reports restrictions as applied', () {
      // The app is provisioning-capable but inert; enforcement ships only
      // after the release path is verified on a device.
      expect(
        DevicePolicyStatus.fromMap(_statusMap()).restrictionsApplied,
        isFalse,
      );
    });
  });

  group('DevicePolicy', () {
    test('status() invokes the native status method', () async {
      final fake = _fakeChannel({'status': _statusMap()});
      final status = await DevicePolicy(fake.channel).status();
      expect(fake.calls.single.method, 'status');
      expect(status.isDeviceOwner, isFalse);
    });

    test('releaseDeviceOwner() forwards the native result', () async {
      final fake = _fakeChannel({'releaseDeviceOwner': true});
      expect(await DevicePolicy(fake.channel).releaseDeviceOwner(), isTrue);
      expect(fake.calls.single.method, 'releaseDeviceOwner');
    });

    test('releaseDeviceOwner() reports failure rather than throwing', () async {
      // The button that calls this is the last resort before a factory reset,
      // so a failure must surface in the UI, never as an unhandled error.
      final fake = _fakeChannel({'releaseDeviceOwner': false});
      expect(await DevicePolicy(fake.channel).releaseDeviceOwner(), isFalse);
    });

    test('releaseDeviceOwner() treats a null reply as failure', () async {
      final fake = _fakeChannel({'releaseDeviceOwner': null});
      expect(await DevicePolicy(fake.channel).releaseDeviceOwner(), isFalse);
    });
  });

  group('StatusPage', () {
    testWidgets('hides the release button when not device owner',
        (tester) async {
      final fake = _fakeChannel({'status': _statusMap()});
      await tester.pumpWidget(
        MaterialApp(home: StatusPage(policy: DevicePolicy(fake.channel))),
      );
      await tester.pumpAndSettle();

      expect(find.text('Release device owner'), findsNothing);
      expect(find.textContaining('Nothing is enforced'), findsOneWidget);
    });

    testWidgets('shows the release button when device owner', (tester) async {
      final fake = _fakeChannel({'status': _statusMap(isDeviceOwner: true)});
      await tester.pumpWidget(
        MaterialApp(home: StatusPage(policy: DevicePolicy(fake.channel))),
      );
      await tester.pumpAndSettle();

      expect(find.text('Release device owner'), findsOneWidget);
      expect(find.text('none (inert build)'), findsOneWidget);
    });

    testWidgets('release is confirmed before it runs', (tester) async {
      final fake = _fakeChannel({
        'status': _statusMap(isDeviceOwner: true),
        'releaseDeviceOwner': true,
      });
      await tester.pumpWidget(
        MaterialApp(home: StatusPage(policy: DevicePolicy(fake.channel))),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Release device owner'));
      await tester.pumpAndSettle();
      expect(find.text('Release device owner?'), findsOneWidget);

      // Cancelling must not call through to the platform.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        fake.calls.where((c) => c.method == 'releaseDeviceOwner'),
        isEmpty,
      );
    });

    testWidgets('confirming release calls the platform', (tester) async {
      final fake = _fakeChannel({
        'status': _statusMap(isDeviceOwner: true),
        'releaseDeviceOwner': true,
      });
      await tester.pumpWidget(
        MaterialApp(home: StatusPage(policy: DevicePolicy(fake.channel))),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Release device owner'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Release'));
      await tester.pumpAndSettle();

      expect(
        fake.calls.where((c) => c.method == 'releaseDeviceOwner'),
        hasLength(1),
      );
      expect(find.text('Device owner released'), findsOneWidget);
    });
  });
}
