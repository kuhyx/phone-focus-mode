/// Sign-in and the encrypted store, copied from wake-alarm's phone_app
/// (`firebase_backend.dart`, `google_sign_in_backend.dart`,
/// `alarm_sync_e2e.dart`): one Google sign-in and one passphrase entry,
/// both kept in the OS keystore.
///
/// The API key, database URL, uid and Web client id are public identifiers
/// that already ship inside phone_app's APK; the security rules protect the
/// data.
library;

import 'package:crdt_sync/crdt_sync.dart';
import 'package:crdt_sync_flutter/crdt_sync_flutter.dart'
    show openEncryptedStoreFromKeystore;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:focus_owner/sync/sync_emulator.dart';
import 'package:google_account_token/google_account_token.dart' as google;

/// The shared `kuhy-syncs` project (regional host).
const kProject = FirebaseProject(
  apiKey: 'AIzaSyCF_sA3xCMehAYXK8eND-rAygb9NXXW_8E',
  databaseUrl:
      'https://kuhy-syncs-default-rtdb.europe-west1.firebasedatabase.app',
);

/// The uid the security rules pin; a wrong account fails loudly.
const kSyncUid = 'OvA2REQyLIhAHOEjzwS1o877rgG3';

/// The project's Web OAuth client id, the audience for Google ID tokens.
const kServerClientId =
    '845446124781-prdoherj0v64vc6egvvcp3l0693khaur.apps.googleusercontent.com';

/// The plaintext prefix the E2E layout derives from (and copies once).
const legacyAlarmPrefix = 'wake-alarm-sync/devices';

/// Where every device's encrypted alarm record lives.
final E2eLayout alarmLayout = E2eLayout.of(legacyAlarmPrefix);

const _secure = FlutterSecureStorage();

// Keystore and plugin calls: platform channels `flutter test` has no binding
// for. The logic lives in crdt_sync, covered there.
// coverage:ignore-start

SecureCredentialStore _credentials() => SecureCredentialStore(
  read: (key) => _secure.read(key: key),
  write: (key, value) => _secure.write(key: key, value: value),
  delete: (key) => _secure.delete(key: key),
);

/// A signed-in client from the stored refresh token (or the emulator), or
/// null when this device was never signed in.
Future<FirebaseRestClient?> openBackend() async {
  if (syncEmulatorOn) return emulatorClient();
  final auth = FirebaseTokenProvider(
    apiKey: kProject.apiKey,
    store: _credentials(),
  );
  if (!await auth.hasSession()) return null;
  return FirebaseRestClient(databaseUrl: kProject.databaseUrl, auth: auth);
}

/// Whether a Google sign-in can work here (Android with a client id).
bool get googleSignInSupported => google.googleAccountTokenSupported;

/// Signs in with the Google account picker. Null when dismissed; throws
/// when the account resolves to a uid the rules do not pin.
Future<FirebaseRestClient?> signInWithGoogle() async {
  final token = await google.googleIdToken(serverClientId: kServerClientId);
  if (token == null) return null;
  final auth = FirebaseTokenProvider(
    apiKey: kProject.apiKey,
    store: _credentials(),
  );
  await auth.signInWithGoogle(idToken: token, expectedUid: kSyncUid);
  return FirebaseRestClient(databaseUrl: kProject.databaseUrl, auth: auth);
}

/// The end-to-end encrypted view of [backend]; throws when no usable
/// passphrase is in the keystore, so nothing is ever pushed in plaintext.
Future<RemoteStore> openSealed(RemoteStore backend) async {
  final state = await openEncryptedStoreFromKeystore(
    store: backend,
    oldPrefix: legacyAlarmPrefix,
  );
  if (state is E2eReady) return state.store;
  throw StateError('sync locked: ${state.runtimeType}');
}

// coverage:ignore-end
