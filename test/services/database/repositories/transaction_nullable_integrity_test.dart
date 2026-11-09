import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/category_transaction.dart';
import 'package:sossoldi/model/transaction.dart';
import 'package:sossoldi/providers/categories_provider.dart';
import 'package:sossoldi/providers/transactions_provider.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sossoldi/services/database/repositories/transactions_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

class _Database extends SossoldiDatabase {
  _Database(this.value);
  Database value;
  @override
  Future<Database> get database async => value;
}

void main() {
  sqfliteFfiInit();
  final instant = DateTime.utc(2032, 9, 7, 12);
  late Database db;
  late _Database database;
  late TransactionsRepository transactions;
  late AccountRepository accounts;
  late ProviderContainer container;
  late Directory temporary;
  late String dbPath;

  setUp(() async {
    final manager = MigrationManager();
    temporary = await Directory.systemTemp.createTemp('nullable_integrity_');
    dbPath = '${temporary.path}/fixture.db';
    db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onCreate: (db, version) => manager.migrate(db, 0, version),
      ),
    );
    database = _Database(db);
    transactions = TransactionsRepository(database: database);
    accounts = AccountRepository(database: database);
    for (final id in [1, 2]) {
      await db.insert(
        bankAccountTable,
        BankAccount(
          id: id,
          name: 'Account $id',
          symbol: 'wallet',
          color: 1,
          startingValue: 100,
          active: true,
          countNetWorth: true,
          mainAccount: id == 1,
          order: id,
          createdAt: instant,
          updatedAt: instant,
        ).toJson(),
      );
    }
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    container.listen(selectedTransactionTypeProvider, (_, _) {});
    container
        .read(filterDateStartProvider.notifier)
        .setDate(DateTime.utc(2032));
    container.read(filterDateEndProvider.notifier).setDate(DateTime.utc(2033));
    container.read(selectedDateProvider.notifier).setDate(instant);
    container
        .read(selectedBankAccountProvider.notifier)
        .setAccount(await accounts.selectById(1));
    container
        .read(selectedCategoryProvider.notifier)
        .setCategory(
          CategoryTransaction(
            id: 11,
            name: 'Category',
            type: CategoryTransactionType.incomeAndExpense,
            symbol: 'question_mark',
            color: 1,
            order: 0,
            createdAt: instant,
            updatedAt: instant,
          ),
        );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(dbPath);
    await temporary.delete(recursive: true);
  });

  Transaction movement(TransactionType type, {int? destination}) => Transaction(
    date: instant,
    amount: 10,
    type: type,
    note: 'Original',
    idBankAccount: 1,
    idBankAccountTransfer: destination,
    idCategory: type == TransactionType.transfer ? null : 11,
    recurring: false,
    createdAt: instant,
    updatedAt: instant,
  );

  Future<void> balances(num source, num destination) async {
    final all = await accounts.selectAll();
    expect(all.singleWhere((item) => item.id == 1).total, source);
    expect(all.singleWhere((item) => item.id == 2).total, destination);
    expect(await accounts.getAccountSum(1), source);
    expect(await accounts.getAccountSum(2), destination);
    final daily = await accounts.accountDailyBalance(2);
    final monthly = await accounts.accountMonthlyBalance(2);
    expect(daily.isEmpty ? 100 : daily.last['balance'], destination);
    expect(monthly.isEmpty ? 100 : monthly.last['balance'], destination);
  }

  for (final type in [TransactionType.expense, TransactionType.income]) {
    test(
      'RG02 changing transfer to $type clears destination and preserves B',
      () async {
        final original = await transactions.insert(
          movement(TransactionType.transfer, destination: 2),
        );
        container.read(selectedTransactionTypeProvider.notifier).setType(type);
        container.read(bankAccountTransferProvider.notifier).setAccount(null);
        await container
            .read(transactionsProvider.notifier)
            .updateTransaction(original, 10, 'Converted');
        final edited = await transactions.selectById(original.id!);
        expect(edited.type, type);
        expect(edited.idBankAccountTransfer, isNull);
        expect(edited.idCategory, 11);
        await balances(type == TransactionType.expense ? 90 : 110, 100);
      },
    );

    test(
      'RG02 legacy $type with stale destination cannot affect B totals',
      () async {
        await transactions.insert(movement(type, destination: 2));
        await balances(type == TransactionType.expense ? 90 : 110, 100);
      },
    );
  }

  test('RG02 converting expense to transfer clears cached category', () async {
    final original = await transactions.insert(
      movement(TransactionType.expense),
    );
    container
        .read(selectedTransactionTypeProvider.notifier)
        .setType(TransactionType.transfer);
    container
        .read(bankAccountTransferProvider.notifier)
        .setAccount(await accounts.selectById(2));
    await container
        .read(transactionsProvider.notifier)
        .updateTransaction(original, 10, 'Converted');
    final edited = await transactions.selectById(original.id!);
    expect(edited.idCategory, isNull);
    expect(edited.idBankAccountTransfer, 2);
    await balances(90, 110);
  });

  test('RG02 create expense ignores a stale transfer selection', () async {
    container
        .read(selectedTransactionTypeProvider.notifier)
        .setType(TransactionType.expense);
    container
        .read(bankAccountTransferProvider.notifier)
        .setAccount(await accounts.selectById(2));
    await container
        .read(transactionsProvider.notifier)
        .create(10, 'New expense');
    final created = (await transactions.selectAll()).single;
    expect(created.idBankAccountTransfer, isNull);
    await balances(90, 100);
  });

  test('RG02 clearing recurrence and note persists nullable values', () async {
    final original = await transactions.insert(
      movement(
        TransactionType.expense,
      ).copy(recurring: true, idRecurringTransaction: 42),
    );
    await transactions.updateItem(
      original.copy(
        note: null,
        idCategory: null,
        idRecurringTransaction: null,
        recurring: false,
      ),
    );
    await db.close();
    final manager = MigrationManager();
    db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onUpgrade: manager.migrate,
      ),
    );
    database.value = db;
    final edited = await transactions.selectById(original.id!);
    expect(edited.note, isNull);
    expect(edited.idCategory, isNull);
    expect(edited.idRecurringTransaction, isNull);
    expect(edited.recurring, isFalse);
  });

  test(
    'RG02 same-account legacy transfer has zero net effect in all readers',
    () async {
      await transactions.insert(
        movement(TransactionType.transfer, destination: 1),
      );
      final all = await accounts.selectAll();
      expect(all.singleWhere((item) => item.id == 1).total, 100);
      expect(await accounts.getAccountSum(1), 100);
    },
  );
}
