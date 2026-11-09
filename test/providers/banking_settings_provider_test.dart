import 'dart:async';
import 'dart:convert';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/providers/banking_provider.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/enable_banking/models/eb_application.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../services/banking/enable_banking_auth_test.dart'
    show testPrivateKeyPem;

class _DelayedContextStore extends EnableBankingCredentialsStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  var delay = false;
  @override
  Future<EnableBankingCredentials?> readCredentials() async {
    final result = await super.readCredentials();
    if (delay && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return result;
  }
}

class _ApplicationApi extends EnableBankingApi {
  _ApplicationApi()
    : super(
        auth: EnableBankingAuth(),
        store: const EnableBankingCredentialsStore(),
      );

  Object? failure;
  int calls = 0;
  Completer<void>? gate;
  Completer<void>? started;

  @override
  Future<EbApplication> verifyApplicationCredentials({
    required String appId,
    required String privateKeyPem,
  }) async {
    calls++;
    started?.complete();
    await gate?.future;
    if (failure case final error?) throw error;
    return EbApplication(
      name: 'Synthetic application',
      kid: appId,
      environment: EnableBankingEnvironment.production,
      active: true,
      services: ['AIS'],
      countries: ['IT'],
      redirectUrls: [kEbRedirectUri],
    );
  }
}

class _Connections extends BankConnectionRepository {
  _Connections(super.database) : super.withDatabase();

  bool failWrites = false;

  @override
  Future<void> markOtherApplicationsReauthRequired(
    String applicationId, {
    required String providerId,
  }) async {
    if (failWrites) throw StateError('Synthetic database write failure');
    await super.markOtherApplicationsReauthRequired(
      applicationId,
      providerId: providerId,
    );
  }

  @override
  Future<void> markAllReauthRequired({required String providerId}) async {
    if (failWrites) throw StateError('Synthetic database write failure');
    await super.markAllReauthRequired(providerId: providerId);
  }
}

void main() {
  const store = EnableBankingCredentialsStore();
  late Database db;
  late _Connections connections;
  late _ApplicationApi api;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    sqfliteFfiInit();
    final manager = MigrationManager();
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onCreate: (db, version) => manager.migrate(db, 0, version),
      ),
    );
    connections = _Connections(db);
    api = _ApplicationApi();
    container = ProviderContainer(
      overrides: [
        enableBankingCredentialsStoreProvider.overrideWithValue(store),
        enableBankingApiProvider.overrideWithValue(api),
        bankConnectionRepositoryProvider.overrideWithValue(connections),
      ],
    );
    await container.read(enableBankingSettingsProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> seedCredentials() => store.saveCredentials(
    appId: 'old-app',
    privateKeyPem: 'old-synthetic-key',
    config: const EnableBankingConfig(
      appId: 'old-app',
      defaultCountry: 'IT',
      supportedCountries: ['IT'],
      redirectUrls: [kEbRedirectUri],
    ),
  );
  Future<BankConnection> seedConnection(
    String applicationId, {
    String providerId = 'enable_banking',
  }) => connections.insert(
    BankConnection(
      providerId: providerId,
      applicationId: applicationId,
      institutionName: 'Synthetic bank',
      institutionCountry: 'IT',
      status: BankConnectionStatus.active,
    ),
  );
  Future<void> save() => container
      .read(enableBankingSettingsProvider.notifier)
      .save(
        appId: 'new-app',
        privateKeyPem: 'new-synthetic-key',
        config: const EnableBankingConfig(
          appId: 'new-app',
          defaultCountry: 'it',
        ),
      );

  test(
    'A32 Settings Clear invalidates cached JWT on a previously obtained API; B recovers',
    () async {
      await store.saveCredentials(
        appId: 'A',
        privateKeyPem: testPrivateKeyPem,
        config: const EnableBankingConfig(appId: 'A'),
      );
      final kids = <String>[];
      final oldApi = EnableBankingApi(
        auth: container.read(enableBankingAuthProvider),
        store: store,
        client: MockClient((request) async {
          final kid =
              JWT
                      .decode(request.headers['Authorization']!.substring(7))
                      .header!['kid']
                  as String;
          kids.add(kid);
          return http.Response(
            jsonEncode({
              'kid': kid,
              'name': 'Synthetic',
              'environment': 'PRODUCTION',
              'active': true,
              'services': ['AIS'],
              'countries': ['IT'],
              'redirect_urls': [kEbRedirectUri],
            }),
            200,
          );
        }),
      );
      await oldApi.getApplication();
      await container.read(enableBankingSettingsProvider.notifier).clear();
      await expectLater(oldApi.getApplication(), throwsA(anything));
      expect(kids, ['A']);
      expect(
        container.read(enableBankingSettingsProvider).requireValue,
        isNull,
      );
      await store.saveCredentials(
        appId: 'B',
        privateKeyPem: testPrivateKeyPem,
        config: const EnableBankingConfig(appId: 'B'),
      );
      await oldApi.getApplication();
      expect(kids, ['A', 'B']);
    },
  );

  test(
    'context read begun before Settings Clear cannot recreate A after B',
    () async {
      final delayed = _DelayedContextStore();
      await delayed.saveCredentials(
        appId: 'A',
        privateKeyPem: testPrivateKeyPem,
        config: const EnableBankingConfig(
          appId: 'A',
          redirectUrls: [kEbRedirectUri],
        ),
      );
      container.dispose();
      container = ProviderContainer(
        overrides: [
          enableBankingCredentialsStoreProvider.overrideWithValue(delayed),
          enableBankingApiProvider.overrideWithValue(api),
          bankConnectionRepositoryProvider.overrideWithValue(connections),
        ],
      );
      await container.read(enableBankingSettingsProvider.future);
      delayed.delay = true;
      final context = readEnableBankingAuthorizationContext(delayed);
      final rejected = expectLater(context, throwsA(anything));
      await delayed.entered.future;
      await container.read(enableBankingSettingsProvider.notifier).clear();
      await delayed.saveCredentials(
        appId: 'B',
        privateKeyPem: testPrivateKeyPem,
        config: const EnableBankingConfig(
          appId: 'B',
          redirectUrls: [kEbRedirectUri],
        ),
      );
      delayed.release.complete();
      await rejected;
      expect(
        (await readEnableBankingAuthorizationContext(delayed)).applicationId,
        'B',
      );
      expect(
        container.read(enableBankingSettingsProvider).requireValue,
        isNull,
      );
    },
  );

  test(
    'late verification cannot overwrite a completed clear or its UI state',
    () async {
      api.gate = Completer<void>();
      api.started = Completer<void>();
      final verification = save();
      await api.started!.future;
      await container.read(enableBankingSettingsProvider.notifier).clear();
      api.gate!.complete();
      await verification;
      expect(await store.readCredentials(), isNull);
      expect(container.read(enableBankingSettingsProvider).hasError, isFalse);
      expect(container.read(enableBankingSettingsProvider).value, isNull);
    },
  );

  test(
    'successful settings verification clears only the matching completed draft',
    () async {
      await store.saveSetupDraft(
        const EnableBankingSetupDraft(
          step: 3,
          existingCredentials: true,
          appId: 'new-app',
          redirectUri: kEbRedirectUri,
          privateKeyPem: 'new-synthetic-key',
        ),
      );
      await save();
      expect(container.read(enableBankingSettingsProvider).hasError, isFalse);
      expect(await store.readSetupDraft(), isNull);
    },
  );

  test(
    'database failure preserves the unfinished draft while rolling back new credentials',
    () async {
      await store.saveSetupDraft(
        const EnableBankingSetupDraft(
          step: 3,
          existingCredentials: true,
          appId: 'new-app',
          privateKeyPem: 'new-synthetic-key',
        ),
      );
      connections.failWrites = true;
      await save();
      expect(container.read(enableBankingSettingsProvider).hasError, isTrue);
      expect(await store.readCredentials(), isNull);
      expect((await store.readSetupDraft())?.appId, 'new-app');
    },
  );

  test(
    'late failure from an older verification cannot replace newer successful settings',
    () async {
      final gate = Completer<void>();
      api.gate = gate;
      api.started = Completer<void>();
      final first = save();
      await api.started!.future;
      api.gate = null;
      api.started = null;
      await save();
      expect(container.read(enableBankingSettingsProvider).hasError, isFalse);
      api.failure = StateError('Synthetic old request failure');
      gate.complete();
      await first;
      expect(container.read(enableBankingSettingsProvider).hasError, isFalse);
      expect(
        container.read(enableBankingSettingsProvider).value?.appId,
        'new-app',
      );
    },
  );

  test('settings read the provider credential store', () async {
    expect(
      await container
          .read(enableBankingSettingsProvider.notifier)
          .hasCredentials(),
      isFalse,
    );
    await seedCredentials();
    container.invalidate(enableBankingSettingsProvider);
    expect(
      (await container.read(enableBankingSettingsProvider.future))?.appId,
      'old-app',
    );
    expect(
      await container
          .read(enableBankingSettingsProvider.notifier)
          .hasCredentials(),
      isTrue,
    );
  });

  test(
    'verified save invalidates only other applications of the selected provider',
    () async {
      await seedCredentials();
      final old = await seedConnection('old-app');
      final same = await seedConnection('new-app');
      final otherProvider = await seedConnection(
        'old-app',
        providerId: 'alternative',
      );
      await save();
      expect(api.calls, 1);
      final saved = container.read(enableBankingSettingsProvider).requireValue!;
      expect(saved.appId, 'new-app');
      expect(saved.defaultCountry, 'IT');
      expect(saved.supportedCountries, ['IT']);
      expect(
        (await store.readCredentials())?.privateKeyPem,
        'new-synthetic-key',
      );
      expect(
        (await connections.selectById(old.id!)).status,
        BankConnectionStatus.reauthRequired,
      );
      expect(
        (await connections.selectById(same.id!)).status,
        BankConnectionStatus.active,
      );
      expect(
        (await connections.selectById(otherProvider.id!)).status,
        BankConnectionStatus.active,
      );
    },
  );

  test(
    'database failure restores the complete previous credential set',
    () async {
      await seedCredentials();
      final previous = await store.readCredentials();
      connections.failWrites = true;
      await save();
      expect(
        container.read(enableBankingSettingsProvider).error,
        isA<StateError>(),
      );
      final restored = await store.readCredentials();
      expect(restored?.config.toJson(), previous!.config.toJson());
      expect(restored?.privateKeyPem, previous.privateKeyPem);
    },
  );

  test(
    'failed first save removes the new credentials when there was no previous set',
    () async {
      connections.failWrites = true;
      await save();
      expect(container.read(enableBankingSettingsProvider).hasError, isTrue);
      expect(await store.readCredentials(), isNull);
    },
  );

  test(
    'verification failure leaves credentials and consent state unchanged',
    () async {
      await seedCredentials();
      final connection = await seedConnection('old-app');
      api.failure = StateError('Synthetic verification failure');
      await save();
      expect(container.read(enableBankingSettingsProvider).hasError, isTrue);
      expect((await store.readCredentials())?.config.appId, 'old-app');
      expect(
        (await connections.selectById(connection.id!)).status,
        BankConnectionStatus.active,
      );
    },
  );

  test(
    'clear invalidates only the selected provider before removing its credentials',
    () async {
      await seedCredentials();
      final connection = await seedConnection('old-app');
      final otherProvider = await seedConnection(
        'old-app',
        providerId: 'alternative',
      );
      await container.read(enableBankingSettingsProvider.notifier).clear();
      expect(
        container.read(enableBankingSettingsProvider).requireValue,
        isNull,
      );
      expect(await store.readCredentials(), isNull);
      expect(
        (await connections.selectById(connection.id!)).status,
        BankConnectionStatus.reauthRequired,
      );
      expect(
        (await connections.selectById(otherProvider.id!)).status,
        BankConnectionStatus.active,
      );
    },
  );

  test(
    'clear preserves credentials when invalidating consents fails',
    () async {
      await seedCredentials();
      connections.failWrites = true;
      await container.read(enableBankingSettingsProvider.notifier).clear();
      expect(container.read(enableBankingSettingsProvider).hasError, isTrue);
      expect((await store.readCredentials())?.config.appId, 'old-app');
    },
  );
}
