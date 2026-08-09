import 'dart:convert';
import 'dart:io';

/// The home coordinates, kept out of the committed policy asset.
///
/// `assets/policy.json` ships with `latitude`/`longitude` null so that the
/// repository never records where the user lives. The real values are pushed
/// to the app's private storage at provisioning time by
/// `scripts/push_home_location.sh`, which reads them from the untracked
/// `phone_focus_mode/config_secrets.sh`.
///
/// Private app storage is not world-readable and does not survive an uninstall,
/// which is the right lifetime for this: reinstalling the app should require
/// re-provisioning rather than silently inheriting a stale home.
class HomeLocationStore {
  const HomeLocationStore(this.file);

  /// Filename written by the provisioning script.
  static const String fileName = 'home_location.json';

  final File file;

  /// Reads the stored coordinates, or null when none have been provisioned.
  ///
  /// Returns null rather than throwing on a malformed or unreadable file. The
  /// caller treats an absent home the same way it treats an absent GPS fix —
  /// as "cannot determine location", which fails closed into enforcing rather
  /// than releasing.
  Future<({double latitude, double longitude})?> read() async {
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      final lat = decoded['latitude'];
      final lon = decoded['longitude'];
      if (lat is! num || lon is! num) return null;
      if (lat.abs() > 90 || lon.abs() > 180) return null;
      return (latitude: lat.toDouble(), longitude: lon.toDouble());
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Writes coordinates, rejecting values that cannot describe a real place.
  Future<void> write(double latitude, double longitude) async {
    if (latitude.abs() > 90 || longitude.abs() > 180) {
      throw ArgumentError('coordinates out of range: $latitude, $longitude');
    }
    await file.writeAsString(
      jsonEncode({'latitude': latitude, 'longitude': longitude}),
    );
  }

  /// Removes any stored coordinates.
  Future<void> clear() async {
    if (file.existsSync()) await file.delete();
  }
}
