
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
}
