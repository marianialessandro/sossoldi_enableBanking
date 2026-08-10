import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'enable_banking_config.dart';

const _kAppIdKey = 'eb_app_id';
const _kPrivateKeyPemKey = 'eb_private_key_pem';
const _kConfigJsonKey = 'eb_config_json';

/// Encrypted persistence for the user's BYOC Enable Banking credentials
/// (Keychain on iOS/macOS, Keystore-backed EncryptedSharedPreferences on
/// Android). The private key is never logged nor exposed beyond this store.
class EnableBankingCredentialsStore {
  final FlutterSecureStorage _storage;

  const EnableBankingCredentialsStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  /// Serializes every write below against [readCredentials], so that method
  /// can never observe a config/private-key pair torn apart by a
  /// saveCredentials()/clear()/clearConfig() landing in the middle of its
  /// two reads. Static rather than per-instance: every
  /// [EnableBankingCredentialsStore] ultimately talks to the same
  /// underlying secure storage backend, const-constructed instances
  /// included, so per-instance locking wouldn't serialize anything.
  static Future<void> _lock = Future.value();

  Future<T> _synchronized<T>(Future<T> Function() action) async {
    final previous = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    await previous;
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }

  Future<void> saveCredentials({
    required String appId,
    required String privateKeyPem,
    required EnableBankingConfig config,
  }) => _synchronized(() async {
    await _storage.write(key: _kAppIdKey, value: appId);
    await _storage.write(key: _kPrivateKeyPemKey, value: privateKeyPem);
    await _storage.write(
      key: _kConfigJsonKey,
      value: jsonEncode(config.toJson()),
    );
  });

  Future<EnableBankingConfig?> readConfig() async {
    final appId = await _storage.read(key: _kAppIdKey);
    if (appId == null) {
      return null;
    }
    final configJson = await _storage.read(key: _kConfigJsonKey);
    if (configJson == null) {
      return EnableBankingConfig(appId: appId);
    }
    return EnableBankingConfig.fromJson(
      jsonDecode(configJson) as Map<String, dynamic>,
    );
  }

  Future<String?> readPrivateKey() => _storage.read(key: _kPrivateKeyPemKey);

  /// Reads `app_id`/config and the private key together as one atomic pair
  /// — used by [EnableBankingAuth.getValidToken] so the signed JWT always
  /// corresponds to an appId/key combination that was actually saved
  /// together, never a mix of a stale and a fresh state.
  Future<(EnableBankingConfig?, String?)> readCredentials() {
    return _synchronized(() async {
      final config = await readConfig();
      final privateKeyPem = await readPrivateKey();
      return (config, privateKeyPem);
    });
  }

  /// Persists a private key on its own, ahead of having an `app_id` for it
  /// (e.g. one just generated on-device, before its certificate has been
  /// registered on the Enable Banking control panel).
  Future<void> savePrivateKey(String privateKeyPem) => _synchronized(
    () => _storage.write(key: _kPrivateKeyPemKey, value: privateKeyPem),
  );

  Future<bool> hasCredentials() async =>
      await _storage.containsKey(key: _kAppIdKey) &&
      await _storage.containsKey(key: _kPrivateKeyPemKey);

  Future<void> clear() => _synchronized(() async {
    await _storage.delete(key: _kAppIdKey);
    await _storage.delete(key: _kPrivateKeyPemKey);
    await _storage.delete(key: _kConfigJsonKey);
  });

  /// Clears `app_id`/config but leaves the private key untouched. Used when
  /// regenerating the key pair: the old `app_id` was tied to the previous
  /// certificate and must not survive, but a private key just written by
  /// [savePrivateKey] must not be wiped out along with it.
  Future<void> clearConfig() => _synchronized(() async {
    await _storage.delete(key: _kAppIdKey);
    await _storage.delete(key: _kConfigJsonKey);
  });
}
