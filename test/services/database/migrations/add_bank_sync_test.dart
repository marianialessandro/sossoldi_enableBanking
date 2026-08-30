import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/model/base_entity.dart';
import 'package:sossoldi/model/transaction.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late String dbPath;
  final manager = MigrationManager();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    dbPath = path.join(
      Directory.systemTemp.path,
      'sossoldi_add_bank_sync_test.db',
    );
  });

  tearDown(() async {
    final file = File(dbPath);
    if (await file.exists()) await file.delete();
  });

  test(
    'upgrading a v7 database to v8 adds bank sync schema without data loss',
    () async {
      final v7db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 7,
          onCreate: (db, version) => manager.migrate(db, 0, version),
        ),
      );

      final accountId = await v7db.insert(bankAccountTable, {
        BankAccountFields.name: 'Revolut',
        BankAccountFields.symbol: 'payments',
        BankAccountFields.color: 1,
        BankAccountFields.startingValue: 1235.10,
        BankAccountFields.active: 1,
        BankAccountFields.mainAccount: 1,
        BaseEntityFields.createdAt: '2026-01-01T00:00:00.000Z',
        BaseEntityFields.updatedAt: '2026-01-01T00:00:00.000Z',
      });

      await v7db.insert(transactionTable, {
        TransactionFields.date: '2026-01-02T00:00:00.000Z',
        TransactionFields.amount: 12.5,
        TransactionFields.type: 'OUT',
        TransactionFields.idBankAccount: accountId,
        TransactionFields.recurring: 0,
        BaseEntityFields.createdAt: '2026-01-02T00:00:00.000Z',
        BaseEntityFields.updatedAt: '2026-01-02T00:00:00.000Z',
      });

      await v7db.close();

      // Reopen at v8: only the onUpgrade path (migration 0008) should run.
      final v8db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 8,
          onUpgrade: (db, oldVersion, newVersion) =>
              manager.migrate(db, oldVersion, newVersion),
        ),
      );

      final accountColumns = (await v8db.rawQuery(
        'PRAGMA table_info($bankAccountTable)',
      )).map((c) => c['name']).toSet();
      expect(
        accountColumns,
        containsAll(<String>[
          BankAccountFields.ebAccountUid,
          BankAccountFields.ebConnectionId,
          BankAccountFields.iban,
          BankAccountFields.lastSyncAt,
        ]),
      );

      final transactionColumns = (await v8db.rawQuery(
        'PRAGMA table_info(`$transactionTable`)',
      )).map((c) => c['name']).toSet();
      expect(transactionColumns, contains(TransactionFields.externalId));

      final connectionColumns = await v8db.rawQuery(
        'PRAGMA table_info($bankConnectionTable)',
      );
      expect(
        connectionColumns.map((c) => c['name']),
        containsAll(BankConnectionFields.allFields),
      );

      final indexes = await v8db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name = 'idx_transaction_external'",
      );
      expect(indexes, isNotEmpty);

      final accounts = await v8db.query(bankAccountTable);
      expect(accounts, hasLength(1));
      expect(accounts.single[BankAccountFields.name], 'Revolut');
      expect(accounts.single[BankAccountFields.ebAccountUid], isNull);

      final transactions = await v8db.query(transactionTable);
      expect(transactions, hasLength(1));
      expect(transactions.single[TransactionFields.amount], 12.5);
      expect(transactions.single[TransactionFields.externalId], isNull);

      await v8db.close();
    },
  );
}
