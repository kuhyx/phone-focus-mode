// Allow/deny decision cases.

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
  TestWidgetsFlutterBinding.ensureInitialized();

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

    test('the launcher is allowed even when absent from the lists', () {
      // Hiding it leaves no home screen. FocusPolicy.kt has always had this
      // check; Dart had drifted without it.
      expect(policy.allowedPackages, isNot(contains(policy.launcherPackage)));
      expect(policy.isAllowed('com.qqlabs.minimalistlauncher'), isTrue);
      expect(
        policy.isAllowed('com.qqlabs.minimalistlauncher', duringCurfew: true),
        isTrue,
      );
    });

    test('an asset without prefix keys parses as empty', () {
      // Back-compat: a policy rendered before prefixes existed must still
      // parse, degrading to exact matching rather than failing entirely.
      expect(policy.allowedPrefixes, isEmpty);
      expect(policy.nightAllowedPrefixes, isEmpty);
    });

    test('allowed prefixes cover a family of packages', () {
      final prefixed = FocusPolicy.fromJson(
        _doc()
          ..['allowed_prefixes'] = ['eu.kanade.tachiyomi']
          ..['night_allowed_prefixes'] = ['eu.kanade.tachiyomi'],
      );
      expect(prefixed.isAllowed('eu.kanade.tachiyomi.sy'), isTrue);
      expect(
        prefixed.isAllowed('eu.kanade.tachiyomi.extension.all.mangadex'),
        isTrue,
      );
      // Whole labels only, so an unrelated package is not swept in.
      expect(prefixed.isAllowed('eu.kanade.tachiyomisomething'), isFalse);
      // Chosen 2026-08-14: manga stays available during the curfew.
      expect(
        prefixed.isAllowed('eu.kanade.tachiyomi.sy', duringCurfew: true),
        isTrue,
      );
    });

    test('a day-only prefix is blocked during curfew', () {
      final dayOnly = FocusPolicy.fromJson(
        _doc()..['allowed_prefixes'] = ['eu.kanade.tachiyomi'],
      );
      expect(dayOnly.isAllowed('eu.kanade.tachiyomi.sy'), isTrue);
      expect(
        dayOnly.isAllowed('eu.kanade.tachiyomi.sy', duringCurfew: true),
        isFalse,
      );
    });

    test('a prefix list of the wrong type is still an error', () {
      // Absent is fine; present-but-wrong is a real mistake.
      expect(
        () => FocusPolicy.fromJson(_doc()..['allowed_prefixes'] = 'nope'),
        throwsA(isA<PolicyFormatException>()),
      );
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
    // Guards against an empty or truncated render, not against a specific
    // size. The threshold was 50 when the allowlist still described the rooted
    // Blackview; the 2026-08-11 rewrite to an explicit list for this phone cut
    // it to ~26, so a high bound would only pin the old policy in place.
    expect(policy.allowedPackages.length, greaterThan(10));
    // The launcher must survive enforcement or the device has no home screen.
    expect(policy.launcherPackage, isNotNull);
    expect(policy.allowedPackages, contains(policy.launcherPackage));
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
