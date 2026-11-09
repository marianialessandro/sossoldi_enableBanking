import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/transaction.dart';
import 'package:sossoldi/providers/accounts_provider.dart';
import 'package:sossoldi/providers/transactions_provider.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/transactions_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

class _Database extends SossoldiDatabase {
  _Database(this.value);
  final Database value;
  @override
  Future<Database> get database async => value;
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late _Database database;
  late TransactionsRepository repository;
  final instant = DateTime.utc(2032, 2, 29, 12);

  setUp(() async {
    final manager = MigrationManager();
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onCreate: (db, version) => manager.migrate(db, 0, version),
      ),
    );
    database = _Database(db);
    repository = TransactionsRepository(database: database);
    for (final id in [1, 2, 3]) {
      await db.insert(
        bankAccountTable,
        BankAccount(
          id: id,
          name: 'Account $id',
          symbol: 'wallet',
          color: 1,
          startingValue: 0,
          active: true,
          countNetWorth: true,
          mainAccount: id == 1,
          order: id,
          createdAt: instant,
          updatedAt: instant,
        ).toJson(),
      );
    }
  });

  tearDown(() => db.close());

  Future<Transaction> insert(
    DateTime date, {
    TransactionType type = TransactionType.transfer,
    int account = 1,
    int? destination = 2,
    String note = "L'acqua",
  }) => repository.insert(
    Transaction(
      date: date,
      amount: 10,
      type: type,
      idBankAccount: account,
      idBankAccountTransfer: destination,
      note: note,
      recurring: false,
      createdAt: instant,
      updatedAt: instant,
    ),
  );

  test(
    'RG05 source and recipient filters both find the same transfer',
    () async {
      final transfer = await insert(instant);
      for (final selected in [1, 2]) {
        final result = await repository.selectAll(
          bankAccounts: {selected: true},
        );
        expect(result.map((item) => item.id), [transfer.id]);
      }
      expect(await repository.selectAll(bankAccounts: {3: true}), isEmpty);
      expect(
        (await repository.selectAll(bankAccounts: {1: true, 2: true})),
        hasLength(1),
      );
    },
  );

  test(
    'RG05 account filter combines recipient, type and apostrophe label',
    () async {
      final transfer = await insert(instant);
      await insert(
        instant,
        type: TransactionType.expense,
        destination: null,
        note: 'Other',
      );
      final filtered = await repository.selectAll(
        bankAccounts: {2: true},
        transactionType: ['TRSF'],
        label: "L'acqua",
      );
      expect(filtered.map((item) => item.id), [transfer.id]);
      expect(
        await repository.selectAll(
          bankAccounts: {2: true},
          transactionType: ['OUT'],
        ),
        isEmpty,
      );
      expect(
        await repository.selectAll(
          bankAccounts: {2: false},
          transactionType: [],
        ),
        hasLength(2),
      );
    },
  );

  test(
    'RG05 a non-transfer with a legacy destination does not match recipient',
    () async {
      await insert(instant, type: TransactionType.expense);
      expect(await repository.selectAll(bankAccounts: {2: true}), isEmpty);
    },
  );

  test('RG05 observed search provider responds to A then B then C', () async {
    final transfer = await insert(instant);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      searchTransactionsProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    await container.read(accountsProvider.future);
    for (final selected in [1, 2, 3]) {
      container.read(filterAccountProvider.notifier).setAccounts({
        selected: true,
      });
      final result = await container.read(searchTransactionsProvider.future);
      expect(
        result.map((item) => item.id),
        selected == 3 ? isEmpty : [transfer.id],
      );
    }
  });

  for (final day in [
    DateTime.utc(2032, 2, 29),
    DateTime.utc(2032, 12, 31),
    DateTime.utc(2033, 1, 1),
    DateTime(2032, 3, 28),
    DateTime(2032, 10, 31),
  ]) {
    test('RG06 whole-day filter includes boundaries for $day', () async {
      DateTime at(
        int year,
        int month,
        int date, [
        int hour = 0,
        int minute = 0,
        int second = 0,
        int millisecond = 0,
      ]) => day.isUtc
          ? DateTime.utc(year, month, date, hour, minute, second, millisecond)
          : DateTime(year, month, date, hour, minute, second, millisecond);
      final next = at(day.year, day.month, day.day + 1);
      final before = await insert(
        at(day.year, day.month, day.day - 1, 23, 59, 59, 999),
      );
      final midnight = await insert(day);
      final noon = await insert(at(day.year, day.month, day.day, 12));
      final late = await insert(
        at(day.year, day.month, day.day, 23, 59, 59, 999),
      );
      final after = await insert(next);
      final expected = {midnight.id, noon.id, late.id};
      for (final query in [
        day,
        at(day.year, day.month, day.day, 12),
        at(day.year, day.month, day.day, 23, 59),
      ]) {
        final matches = await repository.selectAll(date: query);
        expect(matches.map((item) => item.id).toSet(), expected);
        expect(matches.map((item) => item.id), isNot(contains(before.id)));
        expect(matches.map((item) => item.id), isNot(contains(after.id)));
      }
      final ranged = await repository.selectAll(
        dateRangeStart: day,
        dateRangeEnd: day,
      );
      final singleDay = await repository.selectAll(date: day);
      expect(
        singleDay.map((item) => item.id).toList(),
        ranged.map((item) => item.id).toList(),
      );
    });
  }
}
