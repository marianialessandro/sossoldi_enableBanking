import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/banking/lifecycle/banking_backup_policy.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/bank_sync_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/bank_sync_harness.dart';

void main() {
  sqfliteFfiInit();
  late BankSyncHarness harness;
  late Directory temporary;

  setUp(() async {
    harness = BankSyncHarness(databaseFactoryFfi);
    await harness.open();
    expect((await harness.service.syncAccount(1)).completed, isTrue);
    temporary = await Directory.systemTemp.createTemp('bank_csv_integrity_');
  });

  tearDown(() async {
    await harness.close();
    await temporary.delete(recursive: true);
  });

  Future<String> writeCsv(String contents) async {
    final file = File('${temporary.path}/backup.csv');
    await file.writeAsString(contents);
    return file.path;
  }

  Future<Map<String, List<Map<String, Object?>>>> snapshot() async {
    final result = <String, List<Map<String, Object?>>>{};
    for (final table in [
      'bankConnection',
      'bankAccount',
      'transaction',
      'bankRemoteTransaction',
      'bankSyncState',
      'bankSyncAudit',
    ]) {
      result[table] = await harness.db.query(table, orderBy: 'rowid');
    }
    return result;
  }

  Future<void> reopen() async {
    await harness.db.close();
    harness.db = await databaseFactoryFfi.openDatabase(
      harness.path,
      options: OpenDatabaseOptions(
        version: MigrationManager().latestVersion,
        onUpgrade: MigrationManager().migrate,
      ),
    );
    harness.repository = BankSyncRepository.withDatabase(harness.db);
    harness.resetService();
  }

  for (final contents in ['', 'table_name,id', 'table_name,id\r\n\r\n']) {
    test(
      'RG01 rejected empty backup preserves the full ledger: $contents',
      () async {
        final before = await snapshot();
        final database = NativeContractDatabase(harness.db);
        await expectLater(
          database.importFromCSV(await writeCsv(contents)),
          throwsA(isA<Exception>()),
        );
        expect(await snapshot(), before);
        await reopen();
        expect(await snapshot(), before);
        final transactionId = before['transaction']!.single['id'] as int;
        expect(
          await harness.db.query(
            'bankRemoteTransaction',
            where: 'localTransactionId = ?',
            whereArgs: [transactionId],
          ),
          hasLength(1),
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          expect((await harness.service.syncAccount(1)).completed, isTrue);
          final transactions = await harness.transactions();
          expect(transactions, hasLength(1));
          expect(transactions.single['id'], transactionId);
          expect(await harness.total(), closeTo(232.75, 0.000001));
        }
      },
    );
  }

  test(
    'RG01 a failure after one imported table rolls back bank cleanup',
    () async {
      final before = await snapshot();
      final contents = const ListToCsvConverter().convert([
        [
          'table_name',
          'id',
          'date',
          'amount',
          'type',
          'idBankAccount',
          'recurring',
          'createdAt',
          'updatedAt',
        ],
        [
          'transaction',
          777,
          '2026-09-07T12:00:00.000Z',
          1,
          'OUT',
          1,
          0,
          '2026-09-07T12:00:00.000Z',
          '2026-09-07T12:00:00.000Z',
        ],
        ['unknown_table', 1, '', '', '', '', '', '', ''],
      ]);
      await expectLater(
        NativeContractDatabase(
          harness.db,
        ).importFromCSV(await writeCsv(contents)),
        throwsA(isA<Exception>()),
      );
      expect(await snapshot(), before);
      await reopen();
      expect(await snapshot(), before);
    },
  );

  test(
    'RG01 valid bank backup preserves history without reusable sessions',
    () async {
      await harness.db.update('transaction', {
        'note': 'Personal annotation',
        'idCategory': 11,
      });
      final data = await snapshot();
      final original = data['transaction']!.single;
      final headers = <String>{'table_name'};
      for (final rows in data.values) {
        for (final row in rows) {
          headers.addAll(row.keys);
        }
      }
      final columns = headers.toList();
      final rows = <List<Object?>>[columns];
      for (final table in data.entries) {
        for (final row in table.value) {
          final safe = BankingBackupPolicy.sanitizeForExport(table.key, row);
          rows.add([
            table.key,
            for (final column in columns.skip(1)) safe[column] ?? '',
          ]);
        }
      }
      final result = await NativeContractDatabase(
        harness.db,
      ).importFromCSV(await writeCsv(const ListToCsvConverter().convert(rows)));
      expect(result.values, everyElement(isTrue));
      await reopen();
      expect((await harness.transactions()).single, original);
      expect(
        (await harness.db.query('bankConnection')).single['sessionId'],
        isNull,
      );
      expect(
        (await harness.db.query('bankAccount')).single['ebAccountUid'],
        isNull,
      );
      expect(await harness.total(), closeTo(232.75, 0.000001));
    },
  );
  test(
    'RG01+RG08 valid CSV write failure rolls back ledger cleanup and preceding inserts',
    () async {
      final before = await snapshot();
      await harness.db.execute(
        "CREATE TRIGGER reject_second_import BEFORE INSERT ON 'transaction' WHEN NEW.id = 778 BEGIN SELECT RAISE(ABORT, 'synthetic import write failure'); END",
      );
      final rows = <List<Object?>>[
        [
          'table_name',
          'id',
          'date',
          'amount',
          'type',
          'idBankAccount',
          'recurring',
          'createdAt',
          'updatedAt',
        ],
        for (final id in [777, 778])
          [
            'transaction',
            id,
            '2032-09-07T12:00:00.000Z',
            10,
            'OUT',
            1,
            0,
            '2032-09-07T12:00:00.000Z',
            '2032-09-07T12:00:00.000Z',
          ],
      ];
      await expectLater(
        NativeContractDatabase(harness.db).importFromCSV(
          await writeCsv(const ListToCsvConverter().convert(rows)),
        ),
        throwsA(isA<Exception>()),
      );
      expect(await snapshot(), before);
      await reopen();
      expect(await snapshot(), before);
      await harness.db.execute('DROP TRIGGER reject_second_import');
      expect((await harness.service.syncAccount(1)).completed, isTrue);
      expect(await harness.transactions(), hasLength(1));
      expect(await harness.total(), closeTo(232.75, 0.000001));
    },
  );
}
