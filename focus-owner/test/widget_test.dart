
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/device_policy.dart';

/// Builds a channel whose handler answers from [responses], recording calls.
({MethodChannel channel, List<MethodCall> calls}) _fakeChannel(
  Map<String, Object?> responses,
) {
  const channel = MethodChannel('test/device_policy');
  final calls = <MethodCall>[];
  // hasHomeLocation is read on every status refresh, so it is defaulted here
  // rather than restated in each widget test. An explicit stub still wins,
  // which is what the geofence-state tests rely on.
  final stubs = {'hasHomeLocation': false, ...responses};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    if (!stubs.containsKey(call.method)) {
      throw PlatformException(code: 'unimplemented', message: 'no stub');
    }
    return stubs[call.method];
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
  // Explicit since the split moved the testWidgets() group that used to
  // initialise the binding implicitly.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DevicePolicyStatus', () {
    test('parses the native status map', () {
      final status = DevicePolicyStatus.fromMap(_statusMap(isDeviceOwner: true));
      expect(status.packageName, 'com.kuhy.focus_owner');
      expect(status.isDeviceOwner, isTrue);
      expect(status.sdkInt, 36);
    });

    test('this build never reports restrictions as applied', () {
      // Not a claim that nothing is enforced -- the app is live and hiding
      // packages, and it does apply user restrictions once the VPN and DNS
      // layers are locked. The native side simply never reads this back, so
      // it is always false; the real state is the hidden-app count.
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
}
