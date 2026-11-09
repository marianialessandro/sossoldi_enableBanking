import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/providers/accounts_provider.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/services/banking/bank_account_data_source.dart';
import 'package:sossoldi/services/banking/banking_account.dart';
import 'package:sossoldi/services/banking/banking_balance.dart';
import 'package:sossoldi/services/banking/banking_reference.dart';
import 'package:sossoldi/services/banking/banking_request_context.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_deeplink_service.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_session_recovery_store.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_result.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_request.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_service.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/banking/enable_banking_auth_test.dart'
    show testPrivateKeyPem;

class _RecoveryDatabase extends SossoldiDatabase {
  final Database value;
  _RecoveryDatabase(this.value);
  @override
  Future<Database> get database async => value;
}

class _Auth extends EnableBankingAuth {
  @override
  Future<String> getValidToken(EnableBankingCredentialsStore store) async =>
      'synthetic';
}

class RecoveryLinks implements UriLinkSource {
  int starts = 0;
  Uri? initialUri;
  @override
  Stream<Uri> get uriStream => const Stream.empty();
  @override
  Future<Uri?> getInitialUri() async {
    starts++;
    return initialUri;
  }
}

class _Data implements BankAccountDataSource {
  final BankingRecoveryHarness harness;
  _Data(this.harness);
  @override
  Future<BankingAccount> getAccount(
    BankingAccountReference reference, {
    BankingRequestContext context = const BankingRequestContext(),
  }) async {
    harness.accountCalls.add(reference.remoteId);
    harness.contexts.add(Map.of(context.psuHeaders));
    final gate = harness.accountGate;
    if (harness.accountEntered != null &&
        !harness.accountEntered!.isCompleted) {
      harness.accountEntered!.complete();
    }
    await gate?.future;
    final failure = harness.accountFailures[reference.remoteId];
    if (failure != null) throw failure;
    return BankingAccount(
      reference: reference,
      name: 'Checking',
      currency: 'EUR',
    );
  }

  @override
  Future<List<BankingBalance>> getBalances(
    BankingAccountReference reference, {
    BankingRequestContext context = const BankingRequestContext(),
  }) async {
    harness.balanceCalls.add(reference.remoteId);
    harness.contexts.add(Map.of(context.psuHeaders));
    if (harness.balanceEntered != null &&
        !harness.balanceEntered!.isCompleted) {
      harness.balanceEntered!.complete();
    }
    await harness.balanceGate?.future;
    final failure = harness.balanceFailures[reference.remoteId];
    if (failure != null) throw failure;
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Accounts extends Accounts {
  final BankingRecoveryHarness harness;
  _Accounts(this.harness);
  @override
  Future<List<BankAccount>> build() async {
    if (harness.localEntered != null && !harness.localEntered!.isCompleted) {
      harness.localEntered!.complete();
    }
    await harness.localGate?.future;
    return [];
  }
}

class _Sync implements BankSyncService {
  final BankingRecoveryHarness harness;
  _Sync(this.harness);
  @override
  Future<BankSyncSummary> syncConnection(
    int connectionId, {
    BankSyncRequest request = const BankSyncRequest(),
  }) async {
    harness.syncCalls++;
    harness.syncRequests.add(request);
    return BankSyncSummary([]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class BankingRecoveryHarness {
  DateTime now = DateTime.utc(2032, 3, 28, 12);
  final store = const EnableBankingCredentialsStore();
  final pending = const SecurePendingBankAuthorizationStore();
  final journal = const SecureBankSessionRecoveryStore();
  final links = RecoveryLinks();
  late Database db;
  late BankConnectionRepository repository;
  late ProviderContainer container;
  String applicationReply = 'A';
  String remoteStatus = 'AUTHORIZED';
  bool verifyFails = false;
  bool deleteFails = false;
  int deletes = 0;
  int posts = 0;
  int authPosts = 0;
  bool allowSessionCreation = false;
  int deleteStatus = 204;
  String deleteBody = '{}';
  final deletePaths = <String>[];
  Completer<void>? authEntered;
  Completer<void>? authGate;
  int syncCalls = 0;
  final accountCalls = <String>[];
  final balanceCalls = <String>[];
  final contexts = <Map<String, String>>[];
  final syncRequests = <BankSyncRequest>[];
  final accountFailures = <String, Object>{};
  final balanceFailures = <String, Object>{};
  List<String> requiredHeaders = [];
  List<String> remoteUids = ['uid'];
  List<Map<String, Object?>>? remoteAccountsData;
  bool sessionOffline = false;
  bool discoveryOffline = false;
  final sessionFailures = <String, int>{};
  final sessionCalls = <String>[];
  Completer<void>? discoveryEntered;
  Completer<void>? discoveryGate;
  Completer<void>? balanceEntered;
  Completer<void>? balanceGate;
  Completer<void>? deleteEntered;
  Completer<void>? deleteGate;
  Completer<void>? accountEntered;
  Completer<void>? accountGate;
  Completer<void>? localEntered;
  Completer<void>? localGate;

  Future<void> initialize({
    BankSyncService? syncService,
    bool bootstrap = true,
    PendingBankAuthorizationStore? pendingStore,
  }) async {
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
    final api = EnableBankingApi(
      auth: _Auth(),
      store: store,
      client: MockClient((request) async {
        if (request.method == 'DELETE') {
          deletes++;
          deletePaths.add(request.url.path);
          if (deleteEntered != null && !deleteEntered!.isCompleted) {
            deleteEntered!.complete();
          }
          await deleteGate?.future;
          return http.Response(deleteBody, deleteFails ? 500 : deleteStatus);
        }
        if (request.method == 'POST' && request.url.path == '/auth') {
          authPosts++;
          if (authEntered != null && !authEntered!.isCompleted) {
            authEntered!.complete();
          }
          await authGate?.future;
          return http.Response(
            jsonEncode({
              'authorization_id': 'auth-$authPosts',
              'psu_id_hash': 'qa-psu',
              'url': 'https://bank.example/authorize',
            }),
            200,
          );
        }
        if (request.method == 'POST') {
          posts++;
          if (allowSessionCreation && request.url.path == '/sessions') {
            return http.Response(
              jsonEncode({
                'session_id': 'session',
                'aspsp': {'name': 'Test Bank', 'country': 'IT'},
                'psu_type': 'personal',
                'access': {
                  'valid_until': now
                      .add(const Duration(days: 90))
                      .toIso8601String(),
                },
                'accounts': [
                  for (final uid in remoteUids)
                    {'uid': uid, 'identification_hash': 'hash-$uid'},
                ],
              }),
              200,
            );
          }
          throw StateError('Unexpected replay');
        }
        if (request.url.path == '/application') {
          return http.Response(
            jsonEncode({
              'kid': applicationReply,
              'name': 'Synthetic',
              'active': true,
              'environment': 'SANDBOX',
              'services': ['AIS'],
              'countries': ['IT'],
              'redirect_urls': [kEbRedirectUri],
            }),
            verifyFails ? 401 : 200,
          );
        }
        if (request.url.path == '/aspsps') {
          if (discoveryOffline) return http.Response('{}', 503);
          if (discoveryEntered != null && !discoveryEntered!.isCompleted) {
            discoveryEntered!.complete();
          }
          await discoveryGate?.future;
          return http.Response(
            jsonEncode({
              'aspsps': [
                {
                  'name': 'Test Bank',
                  'country': 'IT',
                  'psu_types': ['personal'],
                  'required_psu_headers': requiredHeaders,
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path.startsWith('/sessions/')) {
          sessionCalls.add(request.url.path);
        }
        if (sessionOffline || sessionFailures.containsKey(request.url.path)) {
          return http.Response('{}', sessionFailures[request.url.path] ?? 503);
        }
        return http.Response(
          jsonEncode({
            'status': remoteStatus,
            'aspsp': {'name': 'Test Bank', 'country': 'IT'},
            'psu_type': 'personal',
            'access': {
              'valid_until': now
                  .add(const Duration(days: 90))
                  .toIso8601String(),
            },
            'created': now.toIso8601String(),
            'accounts': remoteUids,
            'accounts_data':
                remoteAccountsData ??
                [
                  for (final uid in remoteUids)
                    {'uid': uid, 'identification_hash': 'hash-$uid'},
                ],
          }),
          200,
        );
      }),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(_RecoveryDatabase(db)),
        if (!bootstrap) bankingUiBootstrapProvider.overrideWith((ref) async {}),
        enableBankingCredentialsStoreProvider.overrideWithValue(store),
        enableBankingApiProvider.overrideWithValue(api),
        bankConnectionRepositoryProvider.overrideWithValue(repository),
        if (pendingStore != null)
          pendingBankAuthorizationStoreProvider.overrideWithValue(pendingStore),
        bankingClockProvider.overrideWithValue(() => now),
        bankDeeplinkServiceProvider.overrideWithValue(
          BankDeeplinkService(source: links),
        ),
        bankAccountDataSourceProvider.overrideWithValue(_Data(this)),
        accountsProvider.overrideWith(() => _Accounts(this)),
        bankSyncServiceProvider.overrideWithValue(syncService ?? _Sync(this)),
      ],
    );
  }

  Future<void> configure(String owner) => store.saveCredentials(
    appId: owner,
    privateKeyPem: testPrivateKeyPem,
    config: EnableBankingConfig(appId: owner, redirectUrls: [kEbRedirectUri]),
  );
  Future<void> saveSettings(String owner) async {
    applicationReply = owner;
    await container
        .read(enableBankingSettingsProvider.notifier)
        .save(
          appId: owner,
          privateKeyPem: testPrivateKeyPem,
          config: EnableBankingConfig(
            appId: owner,
            redirectUrls: [kEbRedirectUri],
          ),
        );
  }

  Future<void> obligation({String owner = 'A', bool unknown = false}) async {
    await journal.upsert(
      BankSessionRecoveryRecord(
        providerId: 'enable_banking',
        applicationId: owner,
        authorizationId: 'cleanup-auth',
        phase: unknown
            ? BankSessionRecoveryPhase.exchangeStarted
            : BankSessionRecoveryPhase.cleanupRequired,
        remoteConnectionId: unknown ? null : 'cleanup-session',
        updatedAt: now,
      ),
    );
  }

  Future<BankConnection> stage({
    String remoteId = 'session',
    String authorizationId = 'auth',
  }) async {
    final connection = await repository.stageConnection(
      providerId: 'enable_banking',
      applicationId: 'A',
      authorizationId: authorizationId,
      institutionName: 'Test Bank',
      institutionCountry: 'IT',
      remoteConnectionId: remoteId,
      validUntil: now.add(const Duration(days: 90)),
      psuType: 'personal',
    );
    await pending.save(
      PendingBankAuthorization(
        providerId: 'enable_banking',
        applicationId: 'A',
        state: 'state-$authorizationId',
        authorizationId: authorizationId,
        authorizationUrl: 'https://bank.example',
        institutionName: 'Test Bank',
        institutionCountry: 'IT',
        redirectUri: kEbRedirectUri,
        expiresAt: now.add(const Duration(minutes: 15)),
        consentValidUntil: connection.pendingValidUntil!,
        stagedConnectionId: connection.id,
        phase: PendingAuthorizationPhase.connectionStaged,
      ),
    );
    return connection;
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}
