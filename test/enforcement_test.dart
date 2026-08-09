import 'package:flutter_test/flutter_test.dart';
import 'package:focus_owner/enforcement.dart';
import 'package:focus_owner/policy.dart';

/// Warsaw, used only as a fixed reference point for the geofence maths.
const double _homeLat = 52.2297;
const double _homeLon = 21.0122;
const double _metresPerDegreeLat = 111320;

FocusPolicy _policy({bool withCoordinates = true, Object? curfew}) =>
    FocusPolicy.fromJson({
      'schema_version': kSupportedSchemaVersion,
      'home': {
        'latitude': withCoordinates ? _homeLat : null,
        'longitude': withCoordinates ? _homeLon : null,
        'radius_m': 150.0,
        'hysteresis_m': 30.0,
      },
      'curfew': curfew ?? const {'start': '23:00', 'end': '05:00'},
      'launcher_package': 'com.launcher',
      'allowed_packages': [
        'com.launcher',
        'pl.mbank',
        'com.discord',
        'com.google.android.youtube',
      ],
      'night_allowed_packages': ['com.launcher', 'pl.mbank'],
      'never_disable_prefixes': ['com.android.settings'],
      'workout_unblock_domains': ['youtube.com', 'googlevideo.com'],
      'browser_packages': <String>[],
    });

const _installed = {
  'com.launcher',
  'pl.mbank',
  'com.discord',
  'com.google.android.youtube',
  'com.evil',
  'com.android.settings',
};

/// A point [metres] north of home.
double _latOffset(double metres) => _homeLat + metres / _metresPerDegreeLat;

void main() {
  group('away from home', () {
    test('nothing is hidden and everything is shown', () {
      final decision = EnforcementDecision.evaluate(
        _policy(),
        EnforcementInputs(
          installedPackages: _installed,
          minutesSinceMidnight: 12 * 60,
          latitude: _latOffset(5000),
          longitude: _homeLon,
        ),
      );
      expect(decision.reason, EnforcementReason.away);
      expect(decision.packagesToHide, isEmpty);
      expect(decision.packagesToShow, _installed);
      expect(decision.isEnforcing, isFalse);
    });
  });

  group('at home during the day', () {
    late EnforcementDecision decision;

    setUp(() {
      decision = EnforcementDecision.evaluate(
        _policy(),
        EnforcementInputs(
          installedPackages: _installed,
          minutesSinceMidnight: 12 * 60,
          latitude: _homeLat,
          longitude: _homeLon,
        ),
      );
    });

    test('only non-allowlisted apps are hidden', () {
      expect(decision.reason, EnforcementReason.atHome);
      expect(decision.packagesToHide, {'com.evil'});
    });

    test('protected system packages are never hidden', () {
      expect(decision.packagesToShow, contains('com.android.settings'));
    });

    test('the launcher is never hidden', () {
      expect(decision.packagesToShow, contains('com.launcher'));
    });
  });

  group('curfew', () {
    test('the night list is much shorter than the day list', () {
      final decision = EnforcementDecision.evaluate(
        _policy(),
        EnforcementInputs(
          installedPackages: _installed,
          minutesSinceMidnight: 23 * 60 + 30,
          latitude: _homeLat,
          longitude: _homeLon,
        ),
      );
      expect(decision.reason, EnforcementReason.curfew);
      expect(decision.packagesToHide, containsAll(['com.discord', 'com.evil']));
      expect(decision.packagesToShow, containsAll(['pl.mbank', 'com.launcher']));
    });

    test('curfew wraps past midnight', () {
      final decision = EnforcementDecision.evaluate(
        _policy(),
        EnforcementInputs(
          installedPackages: _installed,
          minutesSinceMidnight: 3 * 60,
          latitude: _homeLat,
          longitude: _homeLon,
        ),
      );
      expect(decision.reason, EnforcementReason.curfew);
    });

    test('after the curfew ends the day list applies again', () {
      final decision = EnforcementDecision.evaluate(
        _policy(),
        EnforcementInputs(
          installedPackages: _installed,
          minutesSinceMidnight: 6 * 60,
          latitude: _homeLat,
          longitude: _homeLon,
        ),
      );
      expect(decision.reason, EnforcementReason.atHome);
      expect(decision.packagesToShow, contains('com.discord'));
    });
  });

  group('geofence hysteresis', () {
    // 160m is outside the 150m radius but inside radius+hysteresis (180m), so
    // the answer must depend on the current state or the enforcer flaps.
    EnforcementDecision at160m({required bool enforcing}) =>
        EnforcementDecision.evaluate(
          _policy(),
          EnforcementInputs(
            installedPackages: _installed,
            minutesSinceMidnight: 12 * 60,
            latitude: _latOffset(160),
            longitude: _homeLon,
            currentlyEnforcing: enforcing,
          ),
        );

    test('arriving: not yet inside', () {
      expect(at160m(enforcing: false).reason, EnforcementReason.away);
    });

    test('leaving: still inside', () {
      expect(at160m(enforcing: true).reason, EnforcementReason.atHome);
    });

    test('well beyond the band is away in both states', () {
      for (final enforcing in [true, false]) {
        final decision = EnforcementDecision.evaluate(
          _policy(),
          EnforcementInputs(
            installedPackages: _installed,
            minutesSinceMidnight: 12 * 60,
            latitude: _latOffset(500),
            longitude: _homeLon,
            currentlyEnforcing: enforcing,
          ),
        );
        expect(decision.reason, EnforcementReason.away);
      }
    });
  });

  group('fail-closed behaviour', () {
    test('unknown location enforces rather than releasing', () {
      // Losing GPS must not be a way to switch enforcement off. Matches
      // focus_daemon.sh, which defaults to focus mode when location fails.
      final decision = EnforcementDecision.evaluate(
        _policy(),
        EnforcementInputs(
          installedPackages: _installed,
          minutesSinceMidnight: 12 * 60,
        ),
      );
      expect(decision.reason, EnforcementReason.locationUnknown);
      expect(decision.packagesToHide, contains('com.evil'));
    });

    test('a policy with redacted coordinates still enforces', () {
      // The committed policy.json has no coordinates. That must not silently
      // disable the geofence into "always away".
      final decision = EnforcementDecision.evaluate(
        _policy(withCoordinates: false),
        EnforcementInputs(
          installedPackages: _installed,
          minutesSinceMidnight: 12 * 60,
          latitude: _latOffset(5000),
          longitude: _homeLon,
        ),
      );
      expect(decision.packagesToHide, contains('com.evil'));
    });
  });

  group('workout exception', () {
    test('releases YouTube without releasing anything else', () {
      final decision = EnforcementDecision.evaluate(
        _policy(),
        EnforcementInputs(
          installedPackages: _installed,
          minutesSinceMidnight: 23 * 60 + 30,
          latitude: _homeLat,
          longitude: _homeLon,
          workoutActive: true,
        ),
      );
      expect(decision.reason, EnforcementReason.workout);
      expect(decision.packagesToShow, contains('com.google.android.youtube'));
      expect(decision.packagesToHide, contains('com.evil'));
      expect(decision.packagesToHide, contains('com.discord'));
    });

    test('domains map to packages, since hiding cannot target a domain', () {
      expect(
        _policy().workoutExemptPackages,
        contains('com.google.android.youtube'),
      );
    });

    test('no workout domains means no exempt packages', () {
      final policy = FocusPolicy.fromJson({
        'schema_version': kSupportedSchemaVersion,
        'home': {
          'latitude': null,
          'longitude': null,
          'radius_m': 150.0,
          'hysteresis_m': 30.0,
        },
        'curfew': null,
        'launcher_package': null,
        'allowed_packages': <String>[],
        'night_allowed_packages': <String>[],
        'never_disable_prefixes': <String>[],
        'workout_unblock_domains': <String>[],
        'browser_packages': <String>[],
      });
      expect(policy.workoutExemptPackages, isEmpty);
    });
  });

  group('unhide reliability', () {
    test('packagesToShow is the full allowed set, not a delta', () {
      // The service applies packagesToShow unconditionally on every run, so a
      // missed evaluation self-repairs. A delta would require knowing what the
      // previous run did, and a reboot loses that.
      final decision = EnforcementDecision.evaluate(
        _policy(),
        EnforcementInputs(
          installedPackages: _installed,
          minutesSinceMidnight: 12 * 60,
          latitude: _homeLat,
          longitude: _homeLon,
        ),
      );
      final union = {...decision.packagesToHide, ...decision.packagesToShow};
      expect(union, _installed);
      expect(
        decision.packagesToHide.intersection(decision.packagesToShow),
        isEmpty,
      );
    });
  });
}
