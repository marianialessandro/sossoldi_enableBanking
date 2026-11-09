import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/model/transaction.dart';
import 'package:sossoldi/pages/banking/connect_bank_page.dart';
import 'package:sossoldi/providers/accounts_provider.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/services/banking/bank_institution.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_consent_lifecycle_service.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_result.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_session_recovery_store.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sossoldi/ui/theme/app_theme.dart';
import 'package:sqflite/sqflite.dart' hide Transaction;

class _ContractDatabase extends SossoldiDatabase {
  final Database value;
  _ContractDatabase(this.value);
  @override
  Future<Database> get database async => value;
}

class _ContractAuth extends EnableBankingAuth {
  _ContractAuth(DateTime Function() now) : super(now: now);
  @override
  Future<String> getValidToken(EnableBankingCredentialsStore store) async =>
      'synthetic-recovery-token';
}

class _ContractLifecycle extends BankConsentLifecycleService {
  final BankingRecoveryActionsHarness harness;
  _ContractLifecycle(Ref ref, this.harness, EnableBankingApi api)
    : super(
        consent: ref.read(bankConsentServiceProvider),
        institutions: ref.read(bankInstitutionDirectoryProvider),
        readContext: ref.read(bankAuthorizationContextReaderProvider),
        pendingStore: harness.pending,
        recoveryStore: harness.journal,
        connections: harness.repository,
        clock: harness.clock,
        callbackSupported: () => true,
        credentialRevision: () => harness.credentials.credentialRevision,
        cleanupObsoleteConnection: (connection) =>
            cleanupObsoleteEnableBankingConnection(
              store: harness.credentials,
              api: api,
              connection: connection,
            ),
      );
  @override
  Future<AuthorizationLaunchResult> launchAuthorization(
    Uri url, {
    AuthorizationUrlLauncher? launcher,
  }) => super.launchAuthorization(url, launcher: launcher ?? harness.launch);
}

/// The wrapper chooses SQLite and secure storage explicitly; HTTP and browser stay synthetic.
class BankingRecoveryActionsHarness {
  final DatabaseFactory factory;
  final FlutterSecureStorage storage;
  final DateTime Function() clock;
  final PendingBankAuthorizationStore Function(FlutterSecureStorage)?
  pendingFactory;
  late Database db;
  late String path;
  late BankConnectionRepository repository;
  late ProviderContainer container;
  late EnableBankingCredentialsStore credentials;
  late PendingBankAuthorizationStore pending;
  late SecureBankSessionRecoveryStore journal;
  late http.Client _client;
  int posts = 0;
  int sessionPosts = 0;
  int deletes = 0;
  int launches = 0;
  bool browserOpens = false;
  final launchUrls = <Uri>[];
  Completer<void>? authEntered;
  Completer<void>? authGate;
  Completer<void>? launchEntered;
  Completer<void>? launchGate;
  int finishedLaunches = 0;

  BankingRecoveryActionsHarness({
    required this.factory,
    required this.storage,
    DateTime Function()? clock,
    this.pendingFactory,
  }) : clock = clock ?? (() => DateTime.utc(2032, 3, 28, 12));

  BankInstitution institution(String name) => BankInstitution(
    providerId: 'enable_banking',
    id: 'IT:$name',
    name: name,
    country: 'IT',
    customerTypes: {BankingCustomerType.personal},
  );

  Future<void> open() async {
    path =
        '${await factory.getDatabasesPath()}/banking_recovery_qa_${DateTime.now().microsecondsSinceEpoch}.db';
    credentials = EnableBankingCredentialsStore(storage: storage);
    pending =
        pendingFactory?.call(storage) ??
        SecurePendingBankAuthorizationStore(storage: storage);
    journal = SecureBankSessionRecoveryStore(storage: storage);
    await credentials.clear();
    await pending.clear();
    for (final record in await journal.read()) {
      await journal.removeIfCurrent(record);
    }
    await _openDatabase();
    _createContainer();
  }

  Future<void> _openDatabase() async {
    final manager = MigrationManager();
    db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onCreate: (database, version) => manager.migrate(database, 0, version),
      ),
    );
    repository = BankConnectionRepository.withDatabase(db);
  }

  void _createContainer() {
    _client = MockClient((request) async {
      if (request.method == 'DELETE') {
        deletes++;
        return http.Response('{}', 204);
      }
      if (request.url.path == '/auth') {
        posts++;
        if (authEntered != null && !authEntered!.isCompleted) {
          authEntered!.complete();
        }
        await authGate?.future;
        return http.Response(
          jsonEncode({
            'authorization_id': 'qa-auth-$posts',
            'psu_id_hash': 'qa-psu',
            'url': 'https://bank.example/qa',
          }),
          200,
        );
      }
      if (request.url.path == '/aspsps') {
        return http.Response(
          jsonEncode({
            'aspsps': [
              for (final name in ['Bank A', 'Bank B'])
                {
                  'name': name,
                  'country': 'IT',
                  'psu_types': ['personal'],
                },
            ],
          }),
          200,
        );
      }
      if (request.method == 'POST' && request.url.path == '/sessions') {
        sessionPosts++;
        return http.Response(
          jsonEncode({
            'session_id': 'qa-session-callback',
            'aspsp': {'name': 'Bank A', 'country': 'IT'},
            'psu_type': 'personal',
            'access': {
              'valid_until': clock()
                  .add(const Duration(days: 30))
                  .toIso8601String(),
            },
            'accounts': [
              {
                'uid': 'qa-callback-account',
                'identification_hash': 'qa-callback-hash',
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 503);
    });
    final api = EnableBankingApi(
      auth: _ContractAuth(clock),
      store: credentials,
      client: _client,
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(_ContractDatabase(db)),
        bankingClockProvider.overrideWithValue(clock),
        bankingUiBootstrapProvider.overrideWith((ref) async {}),
        enableBankingCredentialsStoreProvider.overrideWithValue(credentials),
        pendingBankAuthorizationStoreProvider.overrideWithValue(pending),
        enableBankingApiProvider.overrideWithValue(api),
        bankConsentLifecycleServiceProvider.overrideWith(
          (ref) => _ContractLifecycle(ref, this, api),
        ),
      ],
    );
  }

  Future<void> configure(String owner) async {
    await credentials.saveCredentials(
      appId: owner,
      privateKeyPem: 'synthetic-not-used-by-contract-auth',
      config: EnableBankingConfig(
        appId: owner,
        supportedCountries: ['IT'],
        redirectUrls: [kEbRedirectUri],
      ),
    );
    container.invalidate(enableBankingSettingsProvider);
  }

  Future<bool> launch(Uri url) async {
    launches++;
    launchUrls.add(url);
    if (launchEntered != null && !launchEntered!.isCompleted) {
      launchEntered!.complete();
    }
    await launchGate?.future;
    finishedLaunches++;
    return browserOpens;
  }

  Future<void> seedPending() => pending.save(
    PendingBankAuthorization(
      providerId: 'enable_banking',
      state: 'qa-state',
      authorizationId: 'qa-pending',
      authorizationUrl: 'https://bank.example/qa',
      applicationId: 'qa-recovery',
      institutionName: 'Bank A',
      institutionCountry: 'IT',
      redirectUri: kEbRedirectUri,
      expiresAt: clock().add(const Duration(minutes: 15)),
      consentValidUntil: clock().add(const Duration(days: 30)),
    ),
  );

  Map<String, Object?> _dated(Map<String, Object?> values) => {
    ...values,
    'createdAt': clock().toIso8601String(),
    'updatedAt': clock().toIso8601String(),
  };

  Future<BankConnection> seedLinked() async {
    final owner = await repository.insert(
      BankConnection(
        providerId: 'enable_banking',
        institutionName: 'Bank A',
        institutionCountry: 'IT',
        applicationId: 'qa-recovery',
        remoteConnectionId: 'qa-session-A',
        validUntil: clock().add(const Duration(days: 30)),
        status: BankConnectionStatus.active,
        createdAt: clock(),
        updatedAt: clock(),
      ),
    );
    final account = BankAccount(
      name: 'Recovery checking',
      symbol: 'account_balance',
      color: 0,
      startingValue: 123,
      active: true,
      countNetWorth: true,
      mainAccount: true,
      order: 0,
      ebConnectionId: owner.id,
      ebAccountUid: 'qa-uid',
    );
    final id = await db.insert('bankAccount', _dated(account.toJson()));
    await db.insert(
      'transaction',
      _dated(
        Transaction(
          date: clock(),
          amount: 7,
          type: TransactionType.expense,
          idBankAccount: id,
          recurring: false,
          note: 'Personal retained note',
        ).toJson(),
      ),
    );
    return owner;
  }

  Future<void> reopen() async {
    container.dispose();
    _client.close();
    await db.close();
    pending =
        pendingFactory?.call(storage) ??
        SecurePendingBankAuthorizationStore(storage: storage);
    await _openDatabase();
    _createContainer();
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.runAsync(() async {
      await container
          .read(connectBankFlowProvider.notifier)
          .refreshAuthorization();
      await container.read(enableBankingSettingsProvider.future);
      final owners = await container.read(bankConnectionsProvider.future);
      await container.read(accountsProvider.future);
      for (final owner in owners) {
        await container.read(
          bankConnectionSyncStatusProvider(owner.id!).future,
        );
      }
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const ConnectBankPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    if (authGate != null && !authGate!.isCompleted) authGate!.complete();
    if (launchGate != null && !launchGate!.isCompleted) launchGate!.complete();
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    _client.close();
    await tester.runAsync(() async {
      await pending.clear();
      for (final record in await journal.read()) {
        await journal.removeIfCurrent(record);
      }
      await credentials.clear();
      expect(await pending.read(), isNull);
      expect(await journal.read(), isEmpty);
      expect(await credentials.readCredentials(), isNull);
      await db.close();
      await factory.deleteDatabase(path);
      expect(await factory.databaseExists(path), isFalse);
    });
  }
}
