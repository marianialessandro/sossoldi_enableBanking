import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/banking/enable_banking_config.dart';
import 'package:sossoldi/services/banking/enable_banking_credentials_store.dart';

/// Lets a test pause [readConfig] mid-flight, so it can force
/// [readCredentials] to still be awaiting its first read while a
/// [saveCredentials] call lands concurrently.
class _GatedCredentialsStore extends EnableBankingCredentialsStore {
  final Completer<void> readConfigGate = Completer<void>();

  @override
  Future<EnableBankingConfig?> readConfig() async {
    await readConfigGate.future;
    return super.readConfig();
  }
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('EnableBankingCredentialsStore', () {
    test('hasCredentials is false before anything is saved', () async {
      final store = const EnableBankingCredentialsStore();
      expect(await store.hasCredentials(), isFalse);
      expect(await store.readConfig(), isNull);
      expect(await store.readPrivateKey(), isNull);
    });

    test('saves and reads back appId, private key and config', () async {
      final store = const EnableBankingCredentialsStore();
      const config = EnableBankingConfig(
        appId: 'app-123',
        environment: EnableBankingEnvironment.sandbox,
        defaultCountry: 'IT',
      );

      await store.saveCredentials(
        appId: 'app-123',
        privateKeyPem:
            '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
        config: config,
      );

      expect(await store.hasCredentials(), isTrue);
      expect(
        await store.readPrivateKey(),
        '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
      );

      final readConfig = await store.readConfig();
      expect(readConfig, isNotNull);
      expect(readConfig!.appId, 'app-123');
      expect(readConfig.environment, EnableBankingEnvironment.sandbox);
      expect(readConfig.defaultCountry, 'IT');
      expect(readConfig.redirectUri, kEbRedirectUri);
      expect(readConfig.baseUrl, 'https://api.enablebanking.com');
    });

    test('savePrivateKey stores a key without an appId or config', () async {
      final store = const EnableBankingCredentialsStore();

      await store.savePrivateKey(
        '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
      );

      expect(
        await store.readPrivateKey(),
        '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
      );
      expect(await store.readConfig(), isNull);
      expect(await store.hasCredentials(), isFalse);
    });

    test('clear removes appId, private key and config', () async {
      final store = const EnableBankingCredentialsStore();
      await store.saveCredentials(
        appId: 'app-123',
        privateKeyPem: 'pem',
        config: const EnableBankingConfig(appId: 'app-123'),
      );

      await store.clear();

      expect(await store.hasCredentials(), isFalse);
      expect(await store.readConfig(), isNull);
      expect(await store.readPrivateKey(), isNull);
    });

    test(
      'clearConfig removes appId and config but keeps the private key',
      () async {
        final store = const EnableBankingCredentialsStore();
        await store.saveCredentials(
          appId: 'app-123',
          privateKeyPem: 'pem',
          config: const EnableBankingConfig(appId: 'app-123'),
        );

        await store.clearConfig();

        expect(await store.hasCredentials(), isFalse);
        expect(await store.readConfig(), isNull);
        expect(await store.readPrivateKey(), 'pem');
      },
    );

    test('readCredentials returns a coherent pair even when saveCredentials '
        'lands concurrently mid-read', () async {
      final store = _GatedCredentialsStore();
      await store.saveCredentials(
        appId: 'old-app',
        privateKeyPem: 'old-pem',
        config: const EnableBankingConfig(appId: 'old-app'),
      );

      // Starts readCredentials(): it acquires the lock, then blocks
      // inside readConfig() on the gate below, still holding the lock.
      final readFuture = store.readCredentials();

      // Queues behind the held lock: must not run until readCredentials
      // above has both read its pair and released the lock.
      final saveFuture = store.saveCredentials(
        appId: 'new-app',
        privateKeyPem: 'new-pem',
        config: const EnableBankingConfig(appId: 'new-app'),
      );

      store.readConfigGate.complete();
      final (config, privateKeyPem) = await readFuture;
      await saveFuture;

      // The pair read must be entirely the old state or entirely the
      // new one — never old appId with new privateKeyPem or vice versa.
      expect(config?.appId, 'old-app');
      expect(privateKeyPem, 'old-pem');

      // The queued write must have gone through once the lock freed up.
      final reloaded = await store.readConfig();
      expect(reloaded?.appId, 'new-app');
      expect(await store.readPrivateKey(), 'new-pem');
    });
  });
}
