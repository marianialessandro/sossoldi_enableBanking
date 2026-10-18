import 'dart:async';
import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sossoldi/services/banking/bank_institution.dart';
import 'package:sossoldi/services/banking/bank_institution_directory.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_auth.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_config.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_consent_service.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_dependencies.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_callback.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_coordinator.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_consent_lifecycle_service.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'enable_banking_auth_test.dart' show testPrivateKeyPem;

final _bank = BankInstitution(
  providerId: 'enable_banking',
  id: 'IT:Test Bank',
  name: 'Test Bank',
  country: 'IT',
  customerTypes: {BankingCustomerType.personal},
);

class _Directory implements BankInstitutionDirectory {
  @override
  Future<List<BankInstitution>> getInstitutions({
    String? country,
    BankingCustomerType customerType = BankingCustomerType.personal,
  }) async => [_bank];
}

class _FailingCleanupStore extends SecurePendingBankAuthorizationStore {
  @override
  Future<void> saveObsoleteConnection(
    ObsoleteBankConnection connection,
  ) async => throw StateError('synthetic storage failure');
}

void main() {
  final now = DateTime.utc(2026, 9, 1);
  late Database db;
  late BankConnectionRepository repository;
  late EnableBankingCredentialsStore store;
  late SecurePendingBankAuthorizationStore pending;
  late EnableBankingApi api;
  late Completer<void> entered;
  late Completer<void> release;
  late List<String> deleteKids;
  var deleteStatus = 204;

  Future<void> configure(String app) => store.saveCredentials(
    appId: app,
    privateKeyPem: testPrivateKeyPem,
    config: EnableBankingConfig(appId: app, redirectUrls: [kEbRedirectUri]),
  );

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
    repository = BankConnectionRepository.withDatabase(db);
    store = const EnableBankingCredentialsStore();
    pending = const SecurePendingBankAuthorizationStore();
    entered = Completer<void>();
    release = Completer<void>();
    deleteKids = [];
    deleteStatus = 204;
    api = EnableBankingApi(
      auth: EnableBankingAuth(now: () => now),
      store: store,
      client: MockClient((request) async {
        if (request.method == 'DELETE') {
          final token = request.headers['Authorization']!.substring(7);
          deleteKids.add(JWT.decode(token).header!['kid'] as String);
          return http.Response('{}', deleteStatus);
        }
        if (request.url.path == '/auth') {
          return http.Response(
            jsonEncode({
              'url': 'https://bank.example/authorize',
              'authorization_id': 'synthetic-authorization',
              'psu_id_hash': 'synthetic-hash',
            }),
            200,
          );
        }
        entered.complete();
        await release.future;
        return http.Response(
          jsonEncode({
            'session_id': 'synthetic-session',
            'aspsp': {'name': 'Test Bank', 'country': 'IT'},
            'access': {
              'valid_until': now
                  .add(const Duration(days: 30))
                  .toIso8601String(),
            },
            'accounts': [],
            'psu_type': 'personal',
          }),
          200,
        );
      }),
    );
    await configure('A');
  });

  tearDown(() => db.close());

  BankConsentLifecycleService lifecycle() => BankConsentLifecycleService(
    consent: EnableBankingConsentService(api),
    institutions: _Directory(),
    readContext: () => readEnableBankingAuthorizationContext(store),
    pendingStore: pending,
    connections: repository,
    clock: () => now,
    callbackSupported: () => true,
    credentialRevision: () => store.credentialRevision,
    cleanupObsoleteConnection: (connection) =>
        cleanupObsoleteEnableBankingConnection(
          store: store,
          api: api,
          connection: connection,
        ),
  );

  for (final action in [
    'Cancel',
    'Clear',
    'B',
    'deleteFailure',
    'storageFailure',
  ]) {
    test(
      'known remote session after $action has owner-safe cleanup or a retained reference',
      () async {
        if (action == 'storageFailure') pending = _FailingCleanupStore();
        final service = lifecycle();
        await service.startAuthorization(_bank);
        final callback = BankAuthorizationCallback(
          code: 'synthetic-code',
          state: (await pending.read())!.state,
        );
        ObsoleteBankAuthorizationException? error;
        final completion = service.completeCallback(callback);
        final rejected = expectLater(
          completion,
          throwsA(
            isA<ObsoleteBankAuthorizationException>().having(
              (value) {
                error = value;
                return value.connection.applicationId;
              },
              'owner',
              'A',
            ),
          ),
        );
        await entered.future;
        if (action == 'Clear') {
          await store.clear();
        } else if (action == 'B') {
          await configure('B');
        } else {
          deleteStatus = action == 'deleteFailure' || action == 'storageFailure'
              ? 500
              : 204;
          await lifecycle().cancelAuthorization();
        }
        release.complete();
        await rejected;
        expect(await repository.selectAwaitingImport(), isEmpty);
        expect(await pending.read(), isNull);
        final confirmed = action == 'Cancel';
        expect(error!.cleanupConfirmed, confirmed);
        expect(
          deleteKids,
          action == 'Clear' || action == 'B' ? isEmpty : ['A'],
        );
        final restored = await const SecurePendingBankAuthorizationStore()
            .readObsoleteConnections();
        expect(
          restored,
          confirmed || action == 'storageFailure' ? isEmpty : hasLength(1),
        );
        if (!confirmed) {
          expect(
            pending.coordinator.unresolvedConnections.single.remoteConnectionId,
            'synthetic-session',
          );
        }
        if (action == 'storageFailure') {
          expect(error!.referencePersisted, isFalse);
        }
        if (action == 'B' || action == 'Clear') {
          await configure('A');
          expect(
            await cleanupObsoleteEnableBankingConnection(
              store: store,
              api: api,
              connection: restored.single,
            ),
            isTrue,
          );
          await pending.removeObsoleteConnection(restored.single);
          expect(await pending.readObsoleteConnections(), isEmpty);
          expect(deleteKids, ['A']);
        }
        final persisted = await const FlutterSecureStorage().read(
          key: 'eb_obsolete_connections_v1',
        );
        expect(persisted ?? '', isNot(contains('synthetic-code')));
        expect(persisted ?? '', isNot(contains('PRIVATE KEY')));
        expect(persisted ?? '', isNot(contains('Bearer')));
      },
    );
  }
}
