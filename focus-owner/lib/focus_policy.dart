/// The FocusPolicy aggregate and its JSON parsing.
///
/// Split out of policy.dart to keep it under the 250-line cap. A `part`
/// rather than a separate library: Dart privates are library-scoped, and
/// this code uses policy.dart's _requireNum and _parseHhMm.

part of 'policy.dart';


/// The device-independent focus policy, as generated from `config.sh`.
class FocusPolicy {
  const FocusPolicy({
    required this.home,
    required this.allowedPackages,
    required this.nightAllowedPackages,
    required this.neverDisablePrefixes,
    required this.workoutUnblockDomains,
    required this.curfew,
    required this.launcherPackage,
    this.allowedPrefixes = const {},
    this.nightAllowedPrefixes = const {},
  });

  /// Parses a rendered policy document.
  factory FocusPolicy.fromJson(Map<String, Object?> json) {
    final version = json['schema_version'];
    if (version != kSupportedSchemaVersion) {
      throw PolicyFormatException(
        'unsupported schema_version $version '
        '(this build understands $kSupportedSchemaVersion)',
      );
    }
    final home = json['home'];
    if (home is! Map<String, Object?>) {
      throw const PolicyFormatException('missing "home" object');
    }
    final curfew = json['curfew'];
    return FocusPolicy(
      home: HomeLocation.fromJson(home),
      allowedPackages: _stringSet(json['allowed_packages'], 'allowed_packages'),
      nightAllowedPackages:
          _stringSet(json['night_allowed_packages'], 'night_allowed_packages'),
      neverDisablePrefixes: _stringSet(
        json['never_disable_prefixes'],
        'never_disable_prefixes',
      ),
      workoutUnblockDomains: _stringSet(
        json['workout_unblock_domains'],
        'workout_unblock_domains',
      ),
      curfew: curfew == null
          ? null
          : CurfewWindow.fromJson(curfew as Map<String, Object?>),
      launcherPackage: json['launcher_package'] as String?,
      // Optional: absent from an asset rendered before prefixes existed, and
      // reading a missing key as empty restores exactly the old exact-match
      // behaviour rather than failing to parse the whole policy.
      allowedPrefixes: _optionalStringSet(
        json,
        'allowed_prefixes',
      ),
      nightAllowedPrefixes: _optionalStringSet(
        json,
        'night_allowed_prefixes',
      ),
    );
  }

  /// Loads the policy bundled with the app.
  static Future<FocusPolicy> load({
    AssetBundle? bundle,
    String assetKey = 'assets/policy.json',
  }) async {
    final raw = await (bundle ?? rootBundle).loadString(assetKey);
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const PolicyFormatException('policy asset is not a JSON object');
    }
    return FocusPolicy.fromJson(decoded);
  }

  final HomeLocation home;
  final Set<String> allowedPackages;
  final Set<String> nightAllowedPackages;
  final Set<String> neverDisablePrefixes;
  final Set<String> workoutUnblockDomains;
  final CurfewWindow? curfew;
  final String? launcherPackage;

  /// Prefix-matched day allowlist, for apps shipping as a package family.
  ///
  /// Tachiyomi installs every source as its own apk, so an exact list goes
  /// stale the moment a new extension is installed.
  final Set<String> allowedPrefixes;

  /// Prefixes that survive the curfew. Subset of [allowedPrefixes].
  final Set<String> nightAllowedPrefixes;

  /// Whether [package] is covered by any entry of [prefixes].
  ///
  /// Matched on whole labels, so `com.android.providers` covers
  /// `com.android.providers.telephony` but not `com.android.providersomething`.
  /// Shared by every prefix list so the boundary rule cannot drift.
  static bool _matchesPrefix(String package, Set<String> prefixes) =>
      prefixes.any(
        (prefix) => package == prefix || package.startsWith('$prefix.'),
      );

  /// Whether a package must never be disabled.
  bool isProtected(String package) =>
      _matchesPrefix(package, neverDisablePrefixes);

  /// Whether a package may run under the given conditions.
  bool isAllowed(String package, {bool duringCurfew = false}) {
    if (isProtected(package)) return true;
    // Hiding the launcher leaves no home screen, so it outranks the lists --
    // matching FocusPolicy.kt, which has always had this check.
    if (package == launcherPackage) return true;
    final allowed = duringCurfew ? nightAllowedPackages : allowedPackages;
    if (allowed.contains(package)) return true;
    final prefixes = duringCurfew ? nightAllowedPrefixes : allowedPrefixes;
    return _matchesPrefix(package, prefixes);
  }

  /// Whether the curfew is in force at [minutesSinceMidnight].
  bool isCurfewActive(int minutesSinceMidnight) =>
      curfew?.contains(minutesSinceMidnight) ?? false;

  /// Packages released while a workout is in progress.
  ///
  /// The rooted system expressed this exception as *domains*, because it
  /// enforced through a hosts file. Hiding apps is a coarser instrument: there
  /// is no way to unblock youtube.com without unhiding the YouTube app, so the
  /// exception is expressed as packages here.
  ///
  /// Derived from [workoutUnblockDomains] rather than configured separately,
  /// so that the shell config stays the single source of truth for *intent*
  /// even though the mechanism differs.
  Set<String> get workoutExemptPackages {
    const domainToPackages = <String, List<String>>{
      'youtube.com': [
        'com.google.android.youtube',
        'com.google.android.apps.youtube.music',
      ],
    };
    final packages = <String>{};
    for (final entry in domainToPackages.entries) {
      final covered = workoutUnblockDomains.any(
        (domain) => domain == entry.key || domain.endsWith('.${entry.key}'),
      );
      if (covered) packages.addAll(entry.value);
    }
    return packages;
  }
}

Set<String> _stringSet(Object? value, String field) {
  if (value is! List) {
    throw PolicyFormatException('"$field" must be a list');
  }
  return value.map((e) => e! as String).toSet();
}

/// A list that may be absent, read as empty.
///
/// Used for fields added after assets were already shipped. The strict
/// [_stringSet] would throw, and an unparsable policy is worse than a missing
/// field: it disables the feature entirely rather than degrading to the
/// previous behaviour. A present-but-wrong type is still an error, since that
/// is a real mistake. Mirrors `optionalStringSet` in `FocusPolicy.kt`.
Set<String> _optionalStringSet(Map<String, Object?> json, String field) {
  if (!json.containsKey(field)) return const {};
  return _stringSet(json[field], field);
}

double _requireNum(Object? value, String field) {
  if (value is! num) {
    throw PolicyFormatException('"$field" must be a number');
  }
  return value.toDouble();
}

int _parseHhMm(Object? value, String field) {
  if (value is! String) {
    throw PolicyFormatException('"$field" must be a "HH:MM" string');
  }
  final parts = value.split(':');
  if (parts.length != 2) {
    throw PolicyFormatException('"$field" must be "HH:MM", got "$value"');
  }
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null || hour > 23 || minute > 59) {
    throw PolicyFormatException('"$field" is not a valid time: "$value"');
  }
  return hour * 60 + minute;
}
