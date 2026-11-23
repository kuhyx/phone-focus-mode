/// The Firebase RTDB emulator on the PC, for AVD checks only.
///
/// A probe build passes `--dart-define=WAKE_SYNC_EMULATOR=http://10.0.2.2:9000`
/// (the AVD's name for the PC loopback); every open then returns this client
/// instead of prod Firebase. Release builds never set it. Same seam as
/// wake-alarm's `phone_app/lib/services/sync_emulator.dart`.
library;

import 'package:crdt_sync/crdt_sync.dart';

/// The emulator's origin, or empty (every release build).
const String kSyncEmulatorUrl = String.fromEnvironment('WAKE_SYNC_EMULATOR');

/// Whether this build syncs to the emulator only.
bool get syncEmulatorOn => kSyncEmulatorUrl.isNotEmpty;

/// Signs every request `auth=owner`, the emulator's admin token.
class EmulatorTokenProvider extends FirebaseTokenProvider {
  /// Creates a provider that never talks to Google.
  EmulatorTokenProvider()
    : super(apiKey: 'emulator', store: InMemoryCredentialStore());

  @override
  Future<String> idToken() async => 'owner';

  @override
  Future<bool> hasSession() async => true;
}

/// A client for the emulator.
FirebaseRestClient emulatorClient() => FirebaseRestClient(
  databaseUrl: kSyncEmulatorUrl,
  auth: EmulatorTokenProvider(),
);
