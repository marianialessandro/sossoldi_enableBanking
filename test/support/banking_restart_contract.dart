import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_provider.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_consent_lifecycle_service.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_deeplink_service.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_session_recovery_store.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_result.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_service.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/repositories/bank_sync_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite/sqflite.dart';

import 'bank_sync_harness.dart';

enum BankingRestartScenario {
  knownReceipt,
  unknownExchange,
  appliedDisconnect,
  awaitingCallback,
}

class _RestartAuth extends EnableBankingAuth {
  @override
  Future<String> getValidToken(EnableBankingCredentialsStore store) async =>
      'synthetic-restart-token';
}

class _ReceiptBoundary implements BankSessionRecoveryStore {
  final SecureBankSessionRecoveryStore backend;
  final Completer<void> entered;
  final Completer<void> release;
  bool hold = false;
  _ReceiptBoundary(this.backend, this.entered, this.release);
  @override
  Future<List<BankSessionRecoveryRecord>> read() => backend.read();
  @override
  Future<bool> removeIfCurrent(BankSessionRecoveryRecord expected) =>
      backend.removeIfCurrent(expected);
  @override
  Future<bool> upsert(
    BankSessionRecoveryRecord record, {
    BankSessionRecoveryRecord? expected,
  }) async {
    final result = await backend.upsert(record, expected: expected);
    if (hold &&
        result &&
        record.phase == BankSessionRecoveryPhase.knownSession) {
      hold = false;
      entered.complete();
      await release.future;
      throw StateError('Controlled host interruption after durable receipt');
    }
    return result;
  }
}

class _PendingBoundary extends SecurePendingBankAuthorizationStore {
  final Completer<void> entered;
  final Completer<void> release;
  bool hold = false;
  _PendingBoundary(FlutterSecureStorage storage, this.entered, this.release)
    : super(storage: storage);
  @override
  Future<void> clear() async {
    if (hold) {
      hold = false;
      entered.complete();
      await release.future;
      throw StateError('Controlled cleanup failure after applied SQL');
    }
    await super.clear();
  }
}

class _InitialSource implements UriLinkSource {
  final Uri? value;
  _InitialSource(this.value);
  @override
  Future<Uri?> getInitialUri() async => value;
  @override
  Stream<Uri> get uriStream => const Stream.empty();
}

class _ObservedInitial implements UriLinkSource {
  final UriLinkSource source;
  Uri? initial;
  int initialReads = 0;
  int streamReceipts = 0;
  _ObservedInitial(this.source);
  @override
  Future<Uri?> getInitialUri() async {
    initialReads++;
    return initial = await source.getInitialUri();
  }

  @override
  Stream<Uri> get uriStream => source.uriStream.map((uri) {
    streamReceipts++;
    return uri;
  });
}

/// A wrapper supplies private native storage or a host mock; no global backend is installed here.
class BankingRestartFixture {
  final DatabaseFactory factory;
  final FlutterSecureStorage storage;
  final Directory directory;
  final String run;
  final BankingRestartScenario scenario;
  final now = DateTime.utc(2032, 3, 28, 12);
  final entered = Completer<void>();
  final release = Completer<void>();
  late Database db;
  late BankConnectionRepository repository;
  late EnableBankingCredentialsStore credentials;
  late _PendingBoundary _pending;
  late SecureBankSessionRecoveryStore journal;
  late _ReceiptBoundary _receipt;
  late EnableBankingApi api;
  late MockClient client;
  late BankConsentLifecycleService lifecycle;
  late BankSyncService sync;
  Future<Object?>? flight;
  int posts = 0;
  int authPosts = 0;
  int deletes = 0;
  final List<String> deletePaths = [];
  bool failDelete = false;
  bool prepareUnknown = false;
  bool _dbOpened = false;
  bool _clientOpened = false;

  BankingRestartFixture({
    required this.factory,
    required this.storage,
    required this.directory,
    required this.run,
    required this.scenario,
  });
  String get path => '${directory.path}/restart.db';
  File get marker => File('${directory.path}/restart-run.json');
  File get callbackHandoff =>
      File('${directory.path}/cold-callback.request.json');

  Future<void> open({required bool existing}) async {
    final manager = MigrationManager();
    if (existing) {
      expect(
        await marker.exists(),
        isTrue,
        reason: 'Recovery cannot reseed a missing prepared run',
      );
      expect(await factory.databaseExists(path), isTrue);
      final saved =
          jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      expect(saved['run'], run);
      expect(saved['scenario'], scenario.name);
    } else {
      expect(await marker.exists(), isFalse);
      expect(await factory.databaseExists(path), isFalse);
      await directory.create(recursive: true);
    }
    db = await factory.openDatabase(
      path,
      options: existing
          ? null
          : OpenDatabaseOptions(
              version: manager.latestVersion,
              onCreate: (db, version) => manager.migrate(db, 0, version),
            ),
    );
    _dbOpened = true;
    expect(await db.getVersion(), manager.latestVersion);
    repository = BankConnectionRepository.withDatabase(db);
    credentials = EnableBankingCredentialsStore(storage: storage);
    _pending = _PendingBoundary(storage, entered, release);
    journal = SecureBankSessionRecoveryStore(storage: storage);
    _receipt = _ReceiptBoundary(journal, entered, release);
    client = MockClient(_respond);
    _clientOpened = true;
    api = EnableBankingApi(
      auth: _RestartAuth(),
      store: credentials,
      client: client,
    );
    final provider = EnableBankingProvider(api);
    lifecycle = BankConsentLifecycleService(
      consent: provider.consent,
      institutions: provider.institutions,
      readContext: () => readEnableBankingAuthorizationContext(credentials),
      pendingStore: _pending,
      recoveryStore: _receipt,
      connections: repository,
      clock: () => now,
      credentialRevision: () => credentials.credentialRevision,
      callbackSupported: () => true,
    );
    sync = BankSyncService(
      accountData: provider.accountData,
      consent: provider.consent,
      institutions: provider.institutions,
      providerId: 'enable_banking',
      repository: BankSyncRepository.withDatabase(db),
      readContext: () => readEnableBankingAuthorizationContext(credentials),
      clock: () => now,
      limits: const BankSyncLimits(
        manualInterval: Duration.zero,
        backgroundInterval: Duration.zero,
      ),
    );
    if (!existing) {
      await _pending.clear();
      for (final record in await journal.read()) {
        await journal.removeIfCurrent(record);
      }
      await credentials.saveCredentials(
        appId: 'restart-app',
        privateKeyPem: 'synthetic-unused-private-key',
        config: const EnableBankingConfig(
          appId: 'restart-app',
          supportedCountries: ['IT'],
          redirectUrls: [kEbRedirectUri],
        ),
      );
      await _seedIndependent();
    }
  }

  http.Response _json(Object value, {int status = 200}) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json', 'date': HttpDate.format(now)},
  );

  Future<http.Response> _respond(http.Request request) async {
    final route = request.url.path;
    if (request.method == 'DELETE') {
      deletes++;
      deletePaths.add(route);
      if (route != '/sessions/restart-known-session') {
        return _json({
          'error': 'Unexpected synthetic cleanup target',
        }, status: 404);
      }
      return _json({}, status: failDelete ? 503 : 204);
    }
    if (route == '/aspsps') {
      return _json({
        'aspsps': [
          {
            'name': 'Restart Bank',
            'country': 'IT',
            'psu_types': ['personal'],
          },
        ],
      });
    }
    if (route == '/auth') {
      authPosts++;
      return _json({
        'authorization_id': 'restart-auth',
        'psu_id_hash': 'synthetic-restart-psu',
        'url': 'https://example.test/restart',
      });
    }
    if (route == '/sessions') {
      posts++;
      if (prepareUnknown) {
        prepareUnknown = false;
        entered.complete();
        await release.future;
        throw http.ClientException('Controlled unknown transport outcome');
      }
      return _json({
        'session_id': 'restart-known-session',
        'aspsp': {'name': 'Restart Bank', 'country': 'IT'},
        'psu_type': 'personal',
        'access': {
          'valid_until': now.add(const Duration(days: 90)).toIso8601String(),
        },
        'accounts': [
          {'uid': 'restart-A-uid', 'identification_hash': 'restart-A-hash'},
        ],
      });
    }
    if (route.endsWith('/details')) {
      return _json({'uid': 'restart-B-uid', 'currency': 'EUR'});
    }
    if (route.endsWith('/transactions')) {
      return _json({
        'transactions': [
          bankRecord(reference: 'restart-B-entry', date: '2032-03-27'),
        ],
      });
    }
    if (route.endsWith('/balances')) {
      return _json({
        'balances': [
          {
            'name': 'Booked',
            'balance_type': 'ITBD',
            'balance_amount': {'amount': '232.75', 'currency': 'EUR'},
            'last_change_date_time': now
                .subtract(const Duration(hours: 1))
                .toIso8601String(),
            'last_committed_transaction': 'restart-B-entry',
          },
        ],
      });
    }
    throw StateError('Unexpected synthetic restart endpoint');
  }

  Future<void> _seedIndependent() async {
    final stamp = now.toIso8601String();
    await db.insert('bankConnection', {
      'id': 2,
      'providerId': 'enable_banking',
      'aspspName': 'Restart Bank',
      'aspspCountry': 'IT',
      'applicationId': 'restart-app',
      'sessionId': 'restart-B-session',
      'status': 'ACTIVE',
      'validUntil': now.add(const Duration(days: 90)).toIso8601String(),
      'createdAt': stamp,
      'updatedAt': stamp,
    });
    await db.insert('bankAccount', {
      'id': 2,
      'name': 'Independent B',
      'symbol': 'wallet',
      'color': 1,
      'startingValue': 0,
      'active': 1,
      'countNetWorth': 1,
      'mainAccount': 0,
      'position': 2,
      'createdAt': stamp,
      'updatedAt': stamp,
      'ebConnectionId': 2,
      'ebAccountUid': 'restart-B-uid',
      'identificationHash': 'restart-B-hash',
    });
    final initialized = await sync.syncAccount(2);
    expect(
      initialized.completed,
      isTrue,
      reason: initialized.warnings.toString(),
    );
  }

  Future<Uri> callback() async {
    final value = (await _pending.read())!;
    return Uri(
      scheme: 'sossoldi',
      host: 'eb-callback',
      queryParameters: {'code': 'synthetic-restart-code', 'state': value.state},
    );
  }

  Future<void> prepare() async {
    final provider = EnableBankingProvider(api);
    final institution = (await provider.institutions.getInstitutions()).single;
    await lifecycle.startAuthorization(institution);
    if (scenario == BankingRestartScenario.knownReceipt ||
        scenario == BankingRestartScenario.unknownExchange) {
      _receipt.hold = scenario == BankingRestartScenario.knownReceipt;
      prepareUnknown = scenario == BankingRestartScenario.unknownExchange;
      final link = await callback();
      flight = lifecycle.completeCallback(BankDeeplinkService.parse(link)!);
      unawaited(
        flight!.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      await entered.future;
      final saved = (await journal.read()).single;
      expect(
        saved.remoteConnectionId,
        scenario == BankingRestartScenario.knownReceipt
            ? 'restart-known-session'
            : isNull,
      );
      expect(
        saved.phase,
        scenario == BankingRestartScenario.knownReceipt
            ? BankSessionRecoveryPhase.knownSession
            : BankSessionRecoveryPhase.outcomeUnknown,
      );
      expect(await repository.selectAwaitingImport(), isEmpty);
    } else if (scenario == BankingRestartScenario.appliedDisconnect) {
      final p = (await _pending.read())!;
      final stamp = now.toIso8601String();
      await db.insert('bankConnection', {
        'id': 1,
        'providerId': 'enable_banking',
        'aspspName': 'Restart Bank',
        'aspspCountry': 'IT',
        'applicationId': 'restart-app',
        'sessionId': 'restart-A-session',
        'pendingSessionId': 'restart-A-_pending',
        'pendingAuthorizationId': p.authorizationId,
        'pendingValidUntil': p.consentValidUntil.toIso8601String(),
        'status': 'ACTIVE',
        'validUntil': p.consentValidUntil.toIso8601String(),
        'createdAt': stamp,
        'updatedAt': stamp,
      });
      await db.insert('bankAccount', {
        'id': 1,
        'name': 'Retained A',
        'symbol': 'wallet',
        'color': 1,
        'startingValue': 123,
        'active': 1,
        'countNetWorth': 1,
        'mainAccount': 0,
        'position': 1,
        'createdAt': stamp,
        'updatedAt': stamp,
        'ebConnectionId': 1,
        'ebAccountUid': 'restart-A-uid',
      });
      await db.insert('transaction', {
        'idBankAccount': 1,
        'amount': 7.0,
        'type': 'OUT',
        'date': stamp,
        'note': 'Private retained history',
        'idCategory': 42,
        'recurring': 0,
        'createdAt': stamp,
        'updatedAt': stamp,
      });
      await _pending.save(
        p.copy(
          stagedConnectionId: 1,
          phase: PendingAuthorizationPhase.connectionStaged,
        ),
      );
      _pending.hold = true;
      flight = lifecycle.disconnectLocally(await repository.selectById(1));
      unawaited(
        flight!.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      await entered.future;
      expect(
        (await repository.selectById(1)).status,
        BankConnectionStatus.disconnected,
      );
      expect(await _pending.read(), isNotNull);
      expect(
        await db.query('transaction', where: 'idBankAccount = 1'),
        hasLength(1),
      );
    } else {
      expect(
        (await _pending.read())!.phase,
        PendingAuthorizationPhase.awaitingCallback,
      );
      await callbackHandoff.writeAsString(
        jsonEncode({'url': (await callback()).toString(), 'run': run}),
        flush: true,
      );
    }
    final snapshot = {
      'run': run,
      'scenario': scenario.name,
      'prepared_pid': pid,
      'boundary_persisted': true,
      'session_posts': posts,
      'auth_posts': authPosts,
      'journal_records': (await journal.read()).length,
      'pending_present': await _pending.read() != null,
      'independent_B_transactions': (await db.query(
        'transaction',
        where: 'idBankAccount = 2',
      )).length,
    };
    await marker.writeAsString(jsonEncode(snapshot), flush: true);
    expect(jsonDecode(await marker.readAsString()), snapshot);
  }

  /// Host reopen releases the simulated fault first; only the coordinated native mode can prove process death.
  Future<void> quiesceHost() async {
    if (flight == null) return;
    failDelete = true;
    if (!release.isCompleted) release.complete();
    try {
      await flight;
    } catch (_) {}
  }

  Future<Map<String, Object?>> recover({
    UriLinkSource? initialSource,
    bool requireNewProcess = false,
  }) async {
    final saved =
        jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
    if (requireNewProcess) expect(saved['prepared_pid'], isNot(pid));
    expect(saved['boundary_persisted'], isTrue);
    expect(posts, 0);
    final report = await lifecycle.recoverSessions();
    var initialReads = 0;
    var initialReceived = false;
    if (scenario == BankingRestartScenario.knownReceipt) {
      expect(report.cleanupConfirmed, 1);
      expect(await journal.read(), isEmpty);
      expect(deletes, 1);
      expect(deletePaths, ['/sessions/restart-known-session']);
      expect(deletePaths, isNot(contains('/sessions/restart-B-session')));
      expect(posts, 0);
      expect(await repository.selectAwaitingImport(), isEmpty);
    } else if (scenario == BankingRestartScenario.unknownExchange) {
      expect(report.unknown, 1);
      final unknown = (await journal.read()).single;
      expect(unknown.phase, BankSessionRecoveryPhase.outcomeUnknown);
      expect(unknown.remoteConnectionId, isNull);
      expect(deletes, 0);
      await expectLater(
        lifecycle.completeCallback(
          BankDeeplinkService.parse(await callback())!,
        ),
        throwsA(isA<BankSessionOutcomeUnknownException>()),
      );
      expect(posts, 0);
      expect((await journal.read()).single.remoteConnectionId, isNull);
    } else if (scenario == BankingRestartScenario.appliedDisconnect) {
      final oldPending = (await _pending.read())!;
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(NativeContractDatabase(db)),
          enableBankingCredentialsStoreProvider.overrideWithValue(credentials),
          pendingBankAuthorizationStoreProvider.overrideWithValue(_pending),
          bankConsentLifecycleServiceProvider.overrideWithValue(lifecycle),
          bankingClockProvider.overrideWithValue(() => now),
        ],
      );
      try {
        final flow = container.read(connectBankFlowProvider.notifier);
        await flow.refreshAuthorization();
        expect(
          container.read(connectBankFlowProvider).pendingCleanup?.state,
          oldPending.state,
        );
        expect(await flow.retryPendingCleanup(), isTrue);
        expect(await _pending.read(), isNull);
        final newer = PendingBankAuthorization.fromJson({
          ...oldPending.toJson(),
          'state': 'independent-new-state',
          'authorization_id': 'independent-B-authorization',
          'phase': PendingAuthorizationPhase.awaitingCallback.code,
        });
        await _pending.save(newer);
        expect(await flow.retryPendingCleanup(oldPending), isTrue);
        expect((await _pending.read())!.toJson(), newer.toJson());
      } finally {
        container.dispose();
      }
      expect(
        (await repository.selectById(1)).status,
        BankConnectionStatus.disconnected,
      );
      final retained = (await db.query(
        'transaction',
        where: 'idBankAccount = 1',
      )).single;
      expect(retained['amount'], 7.0);
      expect(retained['note'], 'Private retained history');
      expect(retained['idCategory'], 42);
      expect(
        (await db.query(
          'bankAccount',
          where: 'id = 1',
        )).single['ebConnectionId'],
        isNull,
      );
      expect(posts, 0);
      expect(deletes, 0);
    } else {
      final expected = await callback();
      final observed = _ObservedInitial(
        initialSource ?? _InitialSource(expected),
      );
      final router = BankDeeplinkService(source: observed);
      final staged = Completer<void>();
      try {
        await router.start(
          (callback) => lifecycle.handleCallback(
            callback,
            onStaged: (_) async {
              if (!staged.isCompleted) staged.complete();
            },
          ),
        );
        await staged.future.timeout(const Duration(minutes: 2));
        expect(
          observed.initial,
          expected,
          reason: 'A stream callback alone is not cold initial-URI evidence',
        );
        expect(observed.initialReads, 1);
        initialReads = observed.initialReads;
        initialReceived = true;
        expect(posts, 1);
        expect(authPosts, 0);
        expect(await repository.selectAwaitingImport(), hasLength(1));
        expect(
          (await _pending.read())!.phase,
          PendingAuthorizationPhase.connectionStaged,
        );
      } finally {
        await router.dispose();
      }
    }
    if (scenario != BankingRestartScenario.knownReceipt) {
      expect(deletePaths, isEmpty);
    }
    final beforeB = await db.query(
      'bankRemoteTransaction',
      where: 'accountId = 2',
    );
    expect((await sync.syncAccount(2)).status, BankSyncStatus.noChange);
    expect(
      await db.query('bankRemoteTransaction', where: 'accountId = 2'),
      beforeB,
    );
    final stateB = (await db.query(
      'bankSyncState',
      where: 'accountId = 2',
    )).single;
    expect(stateB['openingMinor'], '30589');
    expect(stateB['balanceMinor'], '23275');
    expect(
      (await repository.selectById(2)).status,
      BankConnectionStatus.active,
    );
    return {
      'run': run,
      'scenario': scenario.name,
      'prepared_pid': saved['prepared_pid'],
      'recovered_pid': pid,
      'new_process_verified': requireNewProcess,
      'host_or_self_contained_reopen': !requireNewProcess,
      'session_posts_after_restart': posts,
      'auth_posts_after_restart': authPosts,
      'cleanup_confirmed': report.cleanupConfirmed,
      'unknown_outcomes': report.unknown,
      'delete_calls': deletes,
      'delete_paths': List<String>.of(deletePaths),
      'initial_uri_reads': initialReads,
      'initial_uri_received': initialReceived,
      'real_os_initial_source': initialSource is AppLinksUriSource,
      'independent_B_exact_balance': true,
    };
  }

  Future<void> closeHandles() async {
    try {
      if (_clientOpened) client.close();
    } finally {
      if (_dbOpened && db.isOpen) await db.close();
    }
  }

  Future<void> cleanup() async {
    Object? failure;
    StackTrace? failureStack;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }

    await attempt(quiesceHost);
    await attempt(
      () => EnableBankingCredentialsStore(storage: storage).clear(),
    );
    // The wrapper supplies an isolated QA namespace; deleteAll never targets the application store.
    await attempt(() => storage.deleteAll());
    await attempt(() async => expect(await storage.readAll(), isEmpty));
    await attempt(closeHandles);
    await attempt(() => factory.deleteDatabase(path));
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      await attempt(() async {
        final file = File('$path$suffix');
        if (await file.exists()) await file.delete();
        expect(await file.exists(), isFalse);
      });
    }
    await attempt(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
      expect(await directory.exists(), isFalse);
    });
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }
}

Future<void> bankingRestartCleanup(BankingRestartFixture fixture) async {
  await fixture.cleanup();
}

Future<Map<String, Object?>> bankingRestartRecover(
  BankingRestartFixture fixture, {
  UriLinkSource? initialSource,
  bool requireNewProcess = false,
}) async {
  try {
    await fixture.open(existing: true);
    return await fixture.recover(
      initialSource: initialSource,
      requireNewProcess: requireNewProcess,
    );
  } finally {
    await fixture.cleanup();
  }
}

Future<Map<String, Object?>> bankingRestartReopen({
  required DatabaseFactory factory,
  required FlutterSecureStorage Function() storage,
  required BankingRestartScenario scenario,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'bank-restart-${scenario.name}-',
  );
  final prepared = BankingRestartFixture(
    factory: factory,
    storage: storage(),
    directory: directory,
    run: 'self-contained',
    scenario: scenario,
  );
  BankingRestartFixture? recovered;
  try {
    await prepared.open(existing: false);
    await prepared.prepare();
    await prepared.quiesceHost();
    await prepared.closeHandles();
    recovered = BankingRestartFixture(
      factory: factory,
      storage: storage(),
      directory: directory,
      run: 'self-contained',
      scenario: scenario,
    );
    await recovered.open(existing: true);
    return await recovered.recover();
  } finally {
    await (recovered ?? prepared).cleanup();
  }
}
