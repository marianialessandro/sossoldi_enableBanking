import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/services/banking/bank_authorization_context.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_data_mapper.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_provider.dart';
import 'package:sossoldi/services/banking/enable_banking/models/eb_transaction.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_consent_lifecycle_service.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/banking/sync/bank_balance_selector.dart';
import 'package:sossoldi/services/banking/sync/bank_money.dart';
import 'package:sossoldi/services/banking/sync/bank_remote_transaction.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_result.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/repositories/bank_sync_repository.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sqflite/sqflite.dart';

import 'bank_sync_harness.dart';

class _PrivateFactory implements DatabaseFactory {
  final DatabaseFactory backend;
  final Directory directory;
  _PrivateFactory(this.backend, this.directory);
  @override
  Future<String> getDatabasesPath() async => directory.path;
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) =>
      backend.openDatabase(path, options: options);
  @override
  Future<void> deleteDatabase(String path) => backend.deleteDatabase(path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TransactionBoundary implements Database {
  final Database backend;
  void Function()? submitted;
  void Function()? entered;
  final errors = <DatabaseException>[];
  _TransactionBoundary(this.backend);
  @override
  String get path => backend.path;
  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => backend.rawQuery(sql, arguments);
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) {
    final running = backend.transaction((txn) async {
      entered?.call();
      try {
        return await action(txn);
      } on DatabaseException catch (error) {
        errors.add(error);
        rethrow;
      }
    }, exclusive: exclusive);
    submitted?.call();
    return running;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyPendingStore implements PendingBankAuthorizationStore {
  @override
  Future<PendingBankAuthorization?> read() async => null;
  @override
  Future<void> clear() async {}
  @override
  Future<void> save(PendingBankAuthorization pending) async =>
      throw StateError('Restore must not recreate an authorization');
}

const _financialTables = [
  'bankAccount',
  'transaction',
  'bankRemoteTransaction',
  'bankSyncState',
  'bankConnection',
];

Future<Map<String, List<Map<String, Object?>>>> _snapshot(
  DatabaseExecutor db,
) async => {for (final table in _financialTables) table: await db.query(table)};

Future<void> _clean(BankSyncHarness harness, Directory directory) async {
  try {
    try {
      if (harness.db.isOpen) await harness.db.close();
    } finally {
      await harness.factory.deleteDatabase(harness.path);
    }
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      expect(await File('${harness.path}$suffix').exists(), isFalse);
    }
    expect(await directory.list().toList(), isEmpty);
  } finally {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

void _evidence(String scenario, Map<String, Object?> values) =>
    // Synthetic fixtures only; never include live banking credentials or sessions.
    debugPrint(
      'PERSIST_EVIDENCE ${jsonEncode({'scenario': scenario, ...values})}',
    );

/// Registers the same real SQLite and CSV service contracts for explicit host or native backends.
void bankingPersistenceContract(
  DatabaseFactory factory, {
  void Function(String name, Future<void> Function() body)? register,
}) {
  final registerCase = register ?? (name, body) => test(name, body);
  registerCase(
    'PERSIST contention queued repository writer shares one database',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bank-contention-',
      );
      final h = BankSyncHarness(_PrivateFactory(factory, directory));
      await h.open();
      final held = Completer<void>();
      final release = Completer<void>();
      Future<void>? blocker;
      Future<BankSyncResult>? writer;
      try {
        await h.addAccount(2);
        final connection = Map<String, Object?>.of(
          (await h.db.query('bankConnection')).single,
        )..addAll({'id': 2, 'sessionId': 'independent-session'});
        await h.db.insert('bankConnection', connection);
        await h.db.update('bankAccount', {
          'ebConnectionId': 2,
        }, where: 'id = 2');
        expect((await h.service.syncAll()).status, BankSyncStatus.success);
        final before = await _snapshot(h.db);
        final previousAudit = await h.db.query('bankSyncAudit');
        final expected = await h.repository.readContext(2);
        final observed = _TransactionBoundary(h.db);
        final repository = BankSyncRepository.withDatabase(observed);
        final submitted = Completer<void>();
        var bodyEntered = false;
        var completed = false;
        var holding = true;
        observed.submitted = submitted.complete;
        observed.entered = () {
          expect(holding, isFalse);
          bodyEntered = true;
        };
        blocker = h.db.transaction((txn) async {
          await txn.update('bankAccount', {
            'name': 'Held account',
          }, where: 'id = 1');
          held.complete();
          await release.future;
          expect(await txn.query('bankSyncState'), before['bankSyncState']);
          throw StateError('Controlled transaction interruption');
        });
        final rolledBack = expectLater(blocker, throwsA(isA<StateError>()));
        await held.future;
        writer = repository.commit(
          expected,
          [
            BankRemoteTransaction.fromTransaction(
              const EnableBankingDataMapper().transaction(
                EbTransaction.fromJson(bankRecord()),
              ),
              'EUR',
            ),
          ],
          serverTime: h.serverTime,
          strategy: 'longest',
          requiredPsuHeaders: [],
          balance: BankBalanceSnapshot(
            BankMoney.parse('232.75', 'EUR'),
            h.serverTime,
          ),
        );
        unawaited(
          writer.then<void>(
            (_) => completed = true,
            onError: (Object _, StackTrace _) {},
          ),
        );
        await submitted.future;
        observed.submitted = null;
        expect(observed.path, h.db.path);
        expect(bodyEntered, isFalse);
        expect(completed, isFalse);
        holding = false;
        release.complete();
        await rolledBack;
        expect((await writer).status, BankSyncStatus.noChange);
        expect(bodyEntered, isTrue);
        expect(completed, isTrue);
        final after = await _snapshot(h.db);
        expect(after['bankAccount'], before['bankAccount']);
        expect(after['transaction'], before['transaction']);
        expect(after['bankRemoteTransaction'], before['bankRemoteTransaction']);
        expect(after['bankConnection'], before['bankConnection']);
        final states = after['bankSyncState']!;
        expect(
          states.firstWhere((row) => row['accountId'] == 1),
          before['bankSyncState']!.firstWhere((row) => row['accountId'] == 1),
        );
        expect(
          states.firstWhere((row) => row['accountId'] == 2)['revision'],
          expected.revision + 1,
        );
        expect(
          states.every(
            (row) =>
                row['balanceMinor'] == '23275' &&
                row['openingMinor'] == '30589' &&
                row['checkpoint'] == '2026-09-06T00:00:00.000Z',
          ),
          isTrue,
        );
        final currentAudit = await h.db.query('bankSyncAudit');
        expect(
          await repository.recordFailure(
            const BankSyncResult(
              accountId: 2,
              status: BankSyncStatus.terminalFailure,
              warnings: ['obsolete'],
            ),
            expected: expected,
          ),
          isFalse,
        );
        expect(
          await repository.markConsentFailure(
            expected,
            BankConnectionStatus.expired,
          ),
          isFalse,
        );
        expect(await h.db.query('bankSyncAudit'), currentAudit);
        expect(
          currentAudit.firstWhere((row) => row['accountId'] == 1),
          previousAudit.firstWhere((row) => row['accountId'] == 1),
        );
        expect(
          (await h.db.query(
            'bankConnection',
          )).every((row) => row['status'] == 'ACTIVE'),
          isTrue,
        );
        await h.db.close();
        h.db = await h.factory.openDatabase(h.path);
        h.repository = BankSyncRepository.withDatabase(h.db);
        h.resetService();
        expect((await h.service.syncAll()).status, BankSyncStatus.noChange);
        expect(await h.transactions(), hasLength(2));
        _evidence('contention', {
          'same_physical_path': true,
          'queued_at_actual_transaction_submission': true,
          'body_entered_after_release': bodyEntered,
          'rollback_and_independent_commit': true,
          'reopen_idempotent': true,
          'boundary':
              'same-handle sqflite transaction serialization; not OS-lock or independent-handle SQLITE_BUSY',
        });
      } finally {
        if (!release.isCompleted) release.complete();
        if (blocker != null) {
          try {
            await blocker;
          } catch (_) {}
        }
        if (writer != null) {
          try {
            await writer;
          } catch (_) {}
        }
        await _clean(h, directory);
      }
    },
  );

  registerCase(
    'PERSIST allocation real SQLITE_FULL rolls back and recovers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bank-allocation-',
      );
      final h = BankSyncHarness(_PrivateFactory(factory, directory));
      await h.open();
      int? originalQuota;
      try {
        expect((await h.service.syncAccount(1)).completed, isTrue);
        final before = await _snapshot(h.db);
        await h.db.execute('CREATE TABLE quotaProbe(payload BLOB NOT NULL)');
        final pageSize = Sqflite.firstIntValue(
          await h.db.rawQuery('PRAGMA page_size'),
        )!;
        expect(pageSize, inInclusiveRange(512, 65536));
        final allocation = pageSize * 32;
        await h.db.execute(
          'CREATE TRIGGER allocate_probe BEFORE INSERT ON bankRemoteTransaction BEGIN INSERT INTO quotaProbe(payload) VALUES(zeroblob($allocation)); END',
        );
        originalQuota = Sqflite.firstIntValue(
          await h.db.rawQuery('PRAGMA max_page_count'),
        );
        final pages = Sqflite.firstIntValue(
          await h.db.rawQuery('PRAGMA page_count'),
        )!;
        final quota = pages + 2;
        final applied = Sqflite.firstIntValue(
          await h.db.rawQuery('PRAGMA max_page_count = $quota'),
        );
        if (applied != quota) {
          throw UnsupportedError(
            'Backend does not support private max_page_count=$quota; actual=$applied',
          );
        }
        final observed = _TransactionBoundary(h.db);
        h.repository = BankSyncRepository.withDatabase(observed);
        h.resetService();
        h.pages = [
          [bankRecord(), bankRecord(reference: 'allocation', amount: '1.00')],
        ];
        h.balance = '231.75';
        final result = await h.service.syncAccount(1);
        expect(result.completed, isFalse);
        expect(result.warnings, contains('database_commit_failed'));
        expect(
          observed.errors.any(
            (error) =>
                error.getResultCode() == 13 ||
                error.toString().contains('SQLITE_FULL') ||
                error.toString().contains('database or disk is full'),
          ),
          isTrue,
        );
        expect(await _snapshot(h.db), before);
        expect(await h.db.query('quotaProbe'), isEmpty);
        expect(
          (await h.repository.latestResults(1)).accounts.single.status,
          BankSyncStatus.retryableFailure,
        );
        expect(
          Sqflite.firstIntValue(await h.db.rawQuery('PRAGMA page_count')),
          lessThanOrEqualTo(quota),
        );
        await h.db.rawQuery('PRAGMA max_page_count = $originalQuota');
        await h.db.execute('DROP TRIGGER allocate_probe');
        expect((await h.service.syncAccount(1)).completed, isTrue);
        expect((await h.state())['openingMinor'], '30589');
        expect((await h.state())['balanceMinor'], '23175');
        expect(await h.transactions(), hasLength(2));
        await h.db.close();
        h.db = await h.factory.openDatabase(h.path);
        h.repository = BankSyncRepository.withDatabase(h.db);
        h.resetService();
        expect(
          (await h.service.syncAccount(1)).status,
          BankSyncStatus.noChange,
        );
        expect(await h.transactions(), hasLength(2));
        _evidence('allocation', {
          'sqlite_full_observed': true,
          'error_codes': observed.errors
              .map((error) => error.getResultCode())
              .toList(),
          'quota_pages': quota,
          'page_size': pageSize,
          'single_blob_bound_bytes': allocation,
          'financial_rollback': true,
          'retry_and_reopen': true,
          'limit':
              'SQLite private allocation limit only; no physical disk exhaustion',
        });
      } finally {
        try {
          if (h.db.isOpen && originalQuota != null) {
            await h.db.rawQuery('PRAGMA max_page_count = $originalQuota');
          }
        } finally {
          await _clean(h, directory);
        }
      }
    },
  );

  registerCase(
    'PERSIST restore actual CSV round trip strips usable capabilities',
    () async {
      final directory = await Directory.systemTemp.createTemp('bank-restore-');
      final sourceDirectory = await Directory(
        '${directory.path}/source',
      ).create();
      final targetDirectory = await Directory(
        '${directory.path}/target',
      ).create();
      final source = BankSyncHarness(_PrivateFactory(factory, sourceDirectory));
      final target = BankSyncHarness(_PrivateFactory(factory, targetDirectory));
      await source.open();
      await target.open();
      Directory? exportDirectory;
      var exportDirectoryExisted = true;
      final csvFile = File('${directory.path}/synthetic-backup.csv');
      try {
        final documents = await getApplicationDocumentsDirectory();
        exportDirectory = Directory('${documents.path}/sossoldi_exports');
        exportDirectoryExisted = await exportDirectory.exists();
        expect((await source.service.syncAccount(1)).completed, isTrue);
        final now = source.localTime.toIso8601String();
        await source.db.update('transaction', {
          'note': 'Private, note\n"quoted"',
          'idCategory': 42,
        });
        await source.addAccount(2);
        await source.db.update('bankAccount', {
          'name': 'Manual savings',
          'startingValue': 50.0,
          'ebConnectionId': null,
          'ebAccountUid': null,
        }, where: 'id = 2');
        await source.db.insert('transaction', {
          'idBankAccount': 2,
          'amount': 12.5,
          'type': 'IN',
          'note': 'Manual credit',
          'date': now,
          'recurring': 0,
          'createdAt': now,
          'updatedAt': now,
        });
        await source.db.insert('categoryTransaction', {
          'id': 42,
          'name': 'Personal category',
          'type': 'OUT',
          'symbol': 'wallet',
          'color': 1,
          'position': 1,
          'createdAt': now,
          'updatedAt': now,
        });
        await source.db.insert('bankAccountIdentity', {
          'connectionId': 1,
          'bankAccountId': 1,
          'identificationHash': 'stable-1',
        });
        await source.db.update('bankConnection', {
          'pendingSessionId': 'staged-secret',
          'pendingAuthorizationId': 'staged-auth-secret',
          'pendingValidUntil': source.validUntil!.toIso8601String(),
        }, where: 'id = 1');
        for (final (id, status) in [(2, 'REVOKED'), (3, 'DISCONNECTED')]) {
          final row =
              Map<String, Object?>.of(
                (await source.db.query(
                  'bankConnection',
                  where: 'id = 1',
                )).single,
              )..addAll({
                'id': id,
                'sessionId': 'terminal-$id',
                'pendingSessionId': null,
                'pendingAuthorizationId': null,
                'pendingValidUntil': null,
                'status': status,
              });
          await source.db.insert('bankConnection', row);
        }
        final sourceTransactions = await source.transactions();
        final csv = await NativeContractDatabase(source.db).exportToCSV();
        for (final secret in [
          'synthetic-session',
          'synthetic-uid-1',
          'staged-secret',
          'staged-auth-secret',
          'terminal-2',
          'terminal-3',
        ]) {
          expect(csv, isNot(contains(secret)));
        }
        final rows = const CsvToListConverter().convert(csv);
        final headers = rows.first.map((value) => value.toString()).toList();
        final tableColumn = headers.indexOf('table_name');
        final exportedTables = rows
            .skip(1)
            .map((row) => row[tableColumn].toString())
            .toSet();
        await csvFile.writeAsString(csv, flush: true);
        final results = await NativeContractDatabase(
          target.db,
        ).importFromCSV(csvFile.path);
        expect(results.keys.toSet(), exportedTables);
        expect(results.values, everyElement(isTrue));
        await _assertRestored(target, sourceTransactions);
        await target.db.close();
        target.db = await target.factory.openDatabase(target.path);
        target.repository = BankSyncRepository.withDatabase(target.db);
        target.resetService();
        await _assertRestored(target, sourceTransactions);
        for (final row in rows.skip(1)) {
          final table = row[tableColumn];
          if (table == 'bankConnection' && row[headers.indexOf('id')] == 1) {
            for (final entry in {
              'status': 'ACTIVE',
              'sessionId': 'forged-session',
              'pendingSessionId': 'forged-pending',
              'pendingAuthorizationId': 'forged-auth',
              'pendingValidUntil': source.validUntil!.toIso8601String(),
            }.entries) {
              row[headers.indexOf(entry.key)] = entry.value;
            }
          } else if (table == 'bankAccount' &&
              row[headers.indexOf('id')] == 1) {
            row[headers.indexOf('ebAccountUid')] = 'forged-uid';
            row[headers.indexOf('lastSyncAt')] = now;
          } else if (table == 'bankSyncState') {
            row[headers.indexOf('checkpoint')] = now;
            row[headers.indexOf('completedAt')] = now;
          }
        }
        await csvFile.writeAsString(
          const ListToCsvConverter().convert(rows),
          flush: true,
        );
        final untrustedResults = await NativeContractDatabase(
          target.db,
        ).importFromCSV(csvFile.path);
        expect(untrustedResults.keys.toSet(), exportedTables);
        expect(untrustedResults.values, everyElement(isTrue));
        await _assertRestored(target, sourceTransactions);
        target.requests.clear();
        final sync = await target.service.syncAll();
        expect(sync.status, BankSyncStatus.terminalFailure);
        final provider = EnableBankingProvider(target.api);
        final lifecycle = BankConsentLifecycleService(
          consent: provider.consent,
          institutions: provider.institutions,
          readContext: () async => const BankAuthorizationContext(
            providerId: 'enable_banking',
            applicationId: 'synthetic-app',
            redirectUri: 'sossoldi://eb-callback',
          ),
          pendingStore: _EmptyPendingStore(),
          connections: BankConnectionRepository.withDatabase(target.db),
          clock: () => target.localTime,
        );
        expect(await lifecycle.resumeAwaitingImports(), isEmpty);
        expect(target.requests, isEmpty);
        expect(await target.transactions(), sourceTransactions);
        _evidence('restore', {
          'exported_tables': exportedTables.toList(),
          'import_results': results,
          'untrusted_import_results': untrustedResults,
          'reopen_preserves_history': true,
          'protected_http_calls': target.requests.length,
          'limit':
              'actual CSV service and SQLite reopen; no native picker UI or secure-store backup claim',
        });
      } finally {
        try {
          await _clean(source, sourceDirectory);
        } finally {
          try {
            await _clean(target, targetDirectory);
          } finally {
            try {
              try {
                if (await csvFile.exists()) await csvFile.delete();
                expect(await directory.list().toList(), isEmpty);
              } finally {
                if (await directory.exists()) {
                  await directory.delete(recursive: true);
                }
              }
            } finally {
              if (!exportDirectoryExisted &&
                  exportDirectory != null &&
                  await exportDirectory.exists() &&
                  await exportDirectory.list().isEmpty) {
                await exportDirectory.delete();
              }
            }
          }
        }
      }
    },
  );
}

Future<void> _assertRestored(
  BankSyncHarness h,
  List<Map<String, Object?>> transactions,
) async {
  expect(await h.transactions(), transactions);
  final accounts = await h.db.query('bankAccount', orderBy: 'id');
  expect(accounts, hasLength(2));
  expect(accounts.first['startingValue'], 305.89);
  expect(accounts.last['startingValue'], 50.0);
  expect(accounts.last['name'], 'Manual savings');
  expect(
    accounts.every(
      (row) => row['ebAccountUid'] == null && row['lastSyncAt'] == null,
    ),
    isTrue,
  );
  final connections = await h.db.query('bankConnection', orderBy: 'id');
  expect(connections.map((row) => row['status']), [
    'REAUTH_REQUIRED',
    'REVOKED',
    'DISCONNECTED',
  ]);
  for (final row in connections) {
    for (final key in [
      'sessionId',
      'pendingSessionId',
      'pendingAuthorizationId',
      'pendingValidUntil',
    ]) {
      expect(row[key], isNull, reason: key);
    }
  }
  final state = (await h.db.query('bankSyncState')).single;
  expect(state['checkpoint'], isNull);
  expect(state['completedAt'], isNull);
  expect(state['balanceMinor'].toString(), '23275');
  expect(state['openingMinor'].toString(), '30589');
  final ledger = (await h.db.query('bankRemoteTransaction')).single;
  expect(ledger['amountMinor'].toString(), '-7314');
  expect(ledger['noteOverridden'], 1);
  expect(ledger['localNote'], 'Private, note\n"quoted"');
  expect(ledger['localCategory'], 42);
  expect(await h.db.query('bankAccountIdentity'), hasLength(1));
  expect(await h.db.query('bankSyncAudit'), hasLength(1));
  expect(
    (await h.db.query('categoryTransaction', where: 'id = 42')).single['name'],
    'Personal category',
  );
  expect(await h.total(), closeTo(232.75, .000001));
  final projected = await AccountRepository(
    database: NativeContractDatabase(h.db),
  ).selectAll();
  expect(projected.singleWhere((account) => account.id == 2).total, 62.5);
}
