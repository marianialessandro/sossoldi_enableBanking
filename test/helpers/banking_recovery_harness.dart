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
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/banking/enable_banking_auth_test.dart'
    show testPrivateKeyPem;

class _Auth extends EnableBankingAuth {
  @override
  Future<String> getValidToken(EnableBankingCredentialsStore store) async =>
      'synthetic';
}

class RecoveryLinks implements UriLinkSource {
  int starts = 0;
  @override
  Stream<Uri> get uriStream => const Stream.empty();
  @override
  Future<Uri?> getInitialUri() async {
    starts++;
    return null;
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
    final gate = harness.accountGate;
    if (harness.accountEntered != null &&
        !harness.accountEntered!.isCompleted) {
      harness.accountEntered!.complete();
    }
    await gate?.future;
    return BankingAccount(
      reference: reference,
      name: 'Checking',
      currency: 'EUR',
    );
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
    return BankSyncSummary([]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class BankingRecoveryHarness {
  final now = DateTime.utc(2032, 3, 28, 12);
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
  int syncCalls = 0;
  Completer<void>? deleteEntered;
  Completer<void>? deleteGate;
  Completer<void>? accountEntered;
  Completer<void>? accountGate;
  Completer<void>? localEntered;
  Completer<void>? localGate;

  Future<void> initialize() async {
    FlutterSecureStorage.setMockInitialValues({});
    sqfliteFfiInit();
    final manager = MigrationManager();
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 9,
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
          if (deleteEntered != null && !deleteEntered!.isCompleted) {
            deleteEntered!.complete();
          }
          await deleteGate?.future;
          return http.Response('{}', deleteFails ? 500 : 204);
        }
        if (request.method == 'POST') {
          posts++;
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
            'accounts': ['uid'],
            'accounts_data': [
              {'uid': 'uid', 'identification_hash': 'hash'},
            ],
          }),
          200,
        );
      }),
    );
    container = ProviderContainer(
      overrides: [
        enableBankingCredentialsStoreProvider.overrideWithValue(store),
        enableBankingApiProvider.overrideWithValue(api),
        bankConnectionRepositoryProvider.overrideWithValue(repository),
        bankingClockProvider.overrideWithValue(() => now),
        bankDeeplinkServiceProvider.overrideWithValue(
          BankDeeplinkService(source: links),
        ),
        bankAccountDataSourceProvider.overrideWithValue(_Data(this)),
        accountsProvider.overrideWith(() => _Accounts(this)),
        bankSyncServiceProvider.overrideWithValue(_Sync(this)),
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
