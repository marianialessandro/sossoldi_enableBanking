import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'enable_banking_config.dart';

const _kAppIdKey = 'eb_app_id';
const _kPrivateKeyPemKey = 'eb_private_key_pem';
const _kConfigJsonKey = 'eb_config_json';

// Encrypted persistence for BYOC credentials (Keychain/Keystore-backed);
// the private key is never logged nor exposed beyond this store.
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

  // Static lock serializes writes against readCredentials' two reads, so it
  // never observes a torn config/private-key pair.
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

  // Reads config and private key together atomically, so the signed JWT
  // never mixes a stale and a fresh state.
  Future<(EnableBankingConfig?, String?)> readCredentials() {
    return _synchronized(() async {
      final config = await readConfig();
      final privateKeyPem = await readPrivateKey();
      return (config, privateKeyPem);
    });
  }

  // Persists a private key before an app_id exists for it (e.g. one just
  // generated on-device, not yet registered).
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

  // Clears app_id/config only, leaving the private key untouched (used
  // when regenerating the key pair).
  Future<void> clearConfig() => _synchronized(() async {
    await _storage.delete(key: _kAppIdKey);
    await _storage.delete(key: _kConfigJsonKey);
  });
}
