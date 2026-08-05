import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/policy.dart';

Map<String, Object?> _doc({
  Object? schemaVersion = kSupportedSchemaVersion,
  Object? curfew = const {'start': '23:00', 'end': '05:00'},
  double? latitude,
  double? longitude,
}) =>
    {
      'schema_version': schemaVersion,
      'home': {
        'latitude': latitude,
        'longitude': longitude,
        'radius_m': 150.0,
        'hysteresis_m': 30.0,
      },
      'curfew': curfew,
      'launcher_package': 'com.qqlabs.minimalistlauncher',
      'allowed_packages': ['com.good', 'pl.mbank'],
      'night_allowed_packages': ['pl.mbank'],
      'never_disable_prefixes': ['com.android.providers'],
      'workout_unblock_domains': ['youtube.com'],
      'browser_packages': <String>[],
    };

void main() {
  group('FocusPolicy.fromJson', () {
    test('parses a rendered policy', () {
      final policy = FocusPolicy.fromJson(_doc());
      expect(policy.allowedPackages, {'com.good', 'pl.mbank'});
      expect(policy.nightAllowedPackages, {'pl.mbank'});
      expect(policy.launcherPackage, 'com.qqlabs.minimalistlauncher');
      expect(policy.home.radiusM, 150.0);
    });

    test('rejects an unknown schema version', () {
      // Accepting a newer schema would mean enforcing a misread policy.
      expect(
        () => FocusPolicy.fromJson(_doc(schemaVersion: 999)),
        throwsA(isA<PolicyFormatException>()),
      );
    });

    test('rejects a document with no home object', () {
      final doc = _doc()..remove('home');
      expect(
        () => FocusPolicy.fromJson(doc),
        throwsA(isA<PolicyFormatException>()),
      );
    });

    test('rejects a malformed curfew time', () {
      expect(
        () => FocusPolicy.fromJson(_doc(curfew: {'start': '25:00', 'end': 'x'})),
        throwsA(isA<PolicyFormatException>()),
      );
    });

    test('accepts an absent curfew', () {
      expect(FocusPolicy.fromJson(_doc(curfew: null)).curfew, isNull);
    });
  });

  group('HomeLocation', () {
    test('redacted coordinates are reported as absent', () {
      // The committed asset is redacted; enforcement must not treat a missing
      // coordinate as (0, 0), which would put "home" in the Atlantic.
      final policy = FocusPolicy.fromJson(_doc());
      expect(policy.home.hasCoordinates, isFalse);
      expect(policy.home.radiusM, 150.0);
    });

    test('real coordinates are reported as present', () {
      final policy =
          FocusPolicy.fromJson(_doc(latitude: 52.2297, longitude: 21.0122));
      expect(policy.home.hasCoordinates, isTrue);
    });
  });

  group('CurfewWindow', () {
    const window = CurfewWindow(startMinutes: 23 * 60, endMinutes: 5 * 60);

    test('wraps midnight', () {
      expect(window.contains(22 * 60 + 59), isFalse);
      expect(window.contains(23 * 60), isTrue);
      expect(window.contains(0), isTrue);
      expect(window.contains(4 * 60 + 59), isTrue);
      expect(window.contains(5 * 60), isFalse);
      expect(window.contains(12 * 60), isFalse);
    });

    test('handles a same-day window', () {
      const day = CurfewWindow(startMinutes: 9 * 60, endMinutes: 17 * 60);
      expect(day.contains(8 * 60), isFalse);
      expect(day.contains(9 * 60), isTrue);
      expect(day.contains(17 * 60), isFalse);
    });
  });

  group('allow decisions', () {
    final policy = FocusPolicy.fromJson(_doc());

    test('protects system prefixes on whole labels only', () {
      expect(policy.isProtected('com.android.providers'), isTrue);
      expect(policy.isProtected('com.android.providers.telephony'), isTrue);
      expect(policy.isProtected('com.android.providersomething'), isFalse);
    });

    test('protected packages are allowed even during curfew', () {
      expect(
        policy.isAllowed('com.android.providers', duringCurfew: true),
        isTrue,
      );
    });

    test('curfew narrows the allowlist', () {
      expect(policy.isAllowed('com.good'), isTrue);
      expect(policy.isAllowed('com.good', duringCurfew: true), isFalse);
      expect(policy.isAllowed('pl.mbank', duringCurfew: true), isTrue);
    });

    test('unknown packages are blocked', () {
      expect(policy.isAllowed('com.evil'), isFalse);
    });

    test('isCurfewActive follows the window', () {
      expect(policy.isCurfewActive(23 * 60 + 30), isTrue);
      expect(policy.isCurfewActive(12 * 60), isFalse);
    });
  });

  group('FocusPolicy.load', () {
    test('reads and parses the bundled asset', () async {
      final bundle = _StubBundle(jsonEncode(_doc()));
      final policy = await FocusPolicy.load(bundle: bundle);
      expect(policy.allowedPackages, contains('pl.mbank'));
    });

    test('rejects an asset that is not a JSON object', () async {
      final bundle = _StubBundle('[]');
      await expectLater(
        FocusPolicy.load(bundle: bundle),
        throwsA(isA<PolicyFormatException>()),
      );
    });
  });

  test('the real committed asset parses and is redacted', () async {
    // Guards the generator: a policy.json that this app cannot read, or that
    // leaks the home coordinates into git, is a build error.
    final policy = await FocusPolicy.load(bundle: _RealAssetBundle());
    expect(policy.allowedPackages.length, greaterThan(50));
    expect(policy.home.hasCoordinates, isFalse,
        reason: 'committed policy.json must not carry home coordinates');
    expect(policy.curfew, isNotNull);
  });
}

class _StubBundle extends CachingAssetBundle {
  _StubBundle(this.contents);

  final String contents;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(utf8.encode(contents));

  @override
  Future<String> loadString(String key, {bool cache = true}) async => contents;
}

/// Reads the asset straight off disk, bypassing the (empty) test rootBundle.
class _RealAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    throw UnimplementedError(key);
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    final file = File('assets/policy.json');
    return file.readAsString();
  }
}
