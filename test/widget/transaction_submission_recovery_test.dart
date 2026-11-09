import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sossoldi/model/category_transaction.dart';
import 'package:sossoldi/model/transaction.dart';
import 'package:sossoldi/model/recurring_transaction.dart';
import 'package:sossoldi/providers/recurring_transactions_provider.dart';
import 'package:sossoldi/services/database/repositories/recurring_transactions_repository.dart';
import 'package:sossoldi/pages/transactions/create_transaction/create_transaction_page.dart';
import 'package:sossoldi/providers/accounts_provider.dart';
import 'package:sossoldi/providers/categories_provider.dart';
import 'package:sossoldi/providers/settings_provider.dart';
import 'package:sossoldi/providers/transactions_provider.dart';
import 'package:sossoldi/services/database/repositories/transactions_repository.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

class _Database extends SossoldiDatabase {
  _Database(this.value);
  final Database value;
  @override
  Future<Database> get database async => value;
}

class _Harness {
  late Database db;
  late Directory folder;
  Future<void> open() async {
    folder = await Directory.systemTemp.createTemp('transaction_submit_');
    final manager = MigrationManager();
    db = await databaseFactoryFfiNoIsolate.openDatabase(
      '${folder.path}/data.db',
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onCreate: (db, version) => manager.migrate(db, 0, version),
      ),
    );
    await db.insert('bankAccount', {
      'id': 1,
      'name': 'Account',
      'symbol': 'wallet',
      'color': 0,
      'startingValue': 100,
      'active': 1,
      'countNetWorth': 1,
      'mainAccount': 1,
      'position': 0,
      'createdAt': '2032-09-07T12:00:00.000Z',
      'updatedAt': '2032-09-07T12:00:00.000Z',
    });
  }

  Future<void> close() async {
    await db.close();
    await folder.delete(recursive: true);
  }
}

class _DelayedTransactionsRepository extends TransactionsRepository {
  _DelayedTransactionsRepository({required super.database});
  Completer<void>? insertGate;
  Completer<void>? insertEntered;
  bool failProjection = false;

  @override
  Future<Transaction> insert(Transaction item) async {
    if (insertEntered != null && !insertEntered!.isCompleted) {
      insertEntered!.complete();
    }
    await insertGate?.future;
    return super.insert(item);
  }

  @override
  Future<List<Transaction>> selectAll({
    int? type,
    DateTime? date,
    DateTime? dateRangeStart,
    DateTime? dateRangeEnd,
    int? limit,
    List<String>? transactionType,
    String? label,
    Map<int, bool>? bankAccounts,
  }) async {
    if (failProjection) throw StateError('Synthetic projection failure');
    return super.selectAll(
      type: type,
      date: date,
      dateRangeStart: dateRangeStart,
      dateRangeEnd: dateRangeEnd,
      limit: limit,
      transactionType: transactionType,
      label: label,
      bankAccounts: bankAccounts,
    );
  }
}

class _DelayedRecurringRepository extends RecurringTransactionRepository {
  _DelayedRecurringRepository({required super.database});
  Completer<void>? gate;
  Completer<void>? entered;
  bool failRead = false;

  @override
  Future<RecurringTransaction> insertWithTransaction(
    RecurringTransaction item, {
    Transaction? firstTransaction,
  }) async {
    if (entered != null && !entered!.isCompleted) entered!.complete();
    await gate?.future;
    return super.insertWithTransaction(
      item,
      firstTransaction: firstTransaction,
    );
  }

  @override
  Future<List<RecurringTransaction>> selectAllActive({DateTime? now}) async {
    if (failRead) throw StateError('Synthetic recurring projection failure');
    return super.selectAllActive();
  }
}

void main() {
  sqfliteFfiInit();
  late _Harness harness;
  late ProviderContainer container;
  late _DelayedTransactionsRepository repository;
  late int categoryId;
  late _DelayedRecurringRepository recurringRepository;
  final now = DateTime.utc(2032, 9, 7, 12);

  setUp(() async {
    harness = _Harness();
    await harness.open();
    final database = _Database(harness.db);
    repository = _DelayedTransactionsRepository(database: database);
    recurringRepository = _DelayedRecurringRepository(database: database);
    categoryId = await harness.db.insert(
      'categoryTransaction',
      CategoryTransaction(
        name: 'Audit category',
        type: CategoryTransactionType.expense,
        symbol: 'question_mark',
        color: 0,
        order: 0,
        createdAt: now,
        updatedAt: now,
      ).toJson(),
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        sharedPrefProvider.overrideWithValue(prefs),
        transactionsRepositoryProvider.overrideWithValue(repository),
        recurringTransactionRepositoryProvider.overrideWithValue(
          recurringRepository,
        ),
      ],
    );
    await container.read(accountsProvider.future);
    final categories = await container.read(categoriesProvider.future);
    container
        .read(selectedCategoryProvider.notifier)
        .setCategory(categories.singleWhere((item) => item.id == categoryId));
    container
        .read(selectedBankAccountProvider.notifier)
        .setAccount(container.read(accountsProvider).value!.single);
    container.read(selectedDateProvider.notifier).setDate(now);
    container
        .read(filterDateStartProvider.notifier)
        .setDate(DateTime.utc(2032, 9, 1));
    container
        .read(filterDateEndProvider.notifier)
        .setDate(DateTime.utc(2032, 9, 30));
  });

  tearDown(() async {
    container.dispose();
    await harness.close();
  });

  Future<Transaction> existing() => repository.insert(
    Transaction(
      date: now,
      amount: 10,
      type: TransactionType.expense,
      idBankAccount: 1,
      idCategory: categoryId,
      note: 'Before',
      recurring: false,
      createdAt: now,
      updatedAt: now,
    ),
  );

  Future<void> open(WidgetTester tester, Transaction? transaction) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Audit root')),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => CreateTransactionPage(transaction: transaction),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'control normal editor update persists the note and returns to root',
    (tester) async {
      final original = await existing();
      await open(tester, original);
      await tester.enterText(find.byType(TextField).last, 'Edited note');
      await tester.tap(find.text('UPDATE TRANSACTION'));
      await tester.pumpAndSettle();
      expect(find.text('Audit root'), findsOneWidget);
      expect((await repository.selectById(original.id!)).note, 'Edited note');
    },
  );

  testWidgets('N11 failed editor update must keep the editor and draft visible', (
    tester,
  ) async {
    final original = await existing();
    await harness.db.execute(
      "CREATE TRIGGER audit_reject_save BEFORE UPDATE ON 'transaction' BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END",
    );
    await open(tester, original);
    await tester.enterText(find.byType(TextField).last, 'Unsaved note');
    await tester.tap(find.text('UPDATE TRANSACTION'));
    await tester.pumpAndSettle();
    final persisted = await repository.selectById(original.id!);
    final editorVisible = find
        .byType(CreateTransactionPage)
        .evaluate()
        .isNotEmpty;
    expect(
      editorVisible,
      isTrue,
      reason:
          'A failed write must not close the form and discard the user draft.',
    );
    expect(persisted.note, 'Before');
    expect(
      find.text(
        'Could not save transaction. Your changes are still here. Try again.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'Unsaved note',
    );
    await harness.db.execute('DROP TRIGGER audit_reject_save');
    await tester.tap(find.text('UPDATE TRANSACTION'));
    await tester.pumpAndSettle();
    expect(find.text('Audit root'), findsOneWidget);
    expect((await repository.selectById(original.id!)).note, 'Unsaved note');
  });

  testWidgets(
    'N12 rapid repeated add taps must not insert the same draft twice',
    (tester) async {
      repository.insertGate = Completer<void>();
      await open(tester, null);
      await tester.enterText(find.byType(TextField).first, '10');
      await tester.enterText(find.byType(TextField).last, 'Double save');
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD TRANSACTION'));
      await tester.tap(find.text('ADD TRANSACTION'));
      repository.insertGate!.complete();
      await tester.pumpAndSettle();
      final rows = await repository.selectAll(label: 'Double save');
      expect(rows.length, 1);
      expect(find.text('Audit root'), findsOneWidget);
    },
  );

  testWidgets(
    'RG09 a failed new movement keeps the draft and retries exactly once',
    (tester) async {
      await harness.db.execute(
        "CREATE TRIGGER reject_insert BEFORE INSERT ON 'transaction' BEGIN SELECT RAISE(ABORT, 'synthetic insert failure'); END",
      );
      await open(tester, null);
      await tester.enterText(find.byType(TextField).first, '10');
      await tester.enterText(find.byType(TextField).last, 'Retry creation');
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD TRANSACTION'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateTransactionPage), findsOneWidget);
      expect(await repository.selectAll(), isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'Retry creation',
      );
      await harness.db.execute('DROP TRIGGER reject_insert');
      await tester.tap(find.text('ADD TRANSACTION'));
      await tester.pumpAndSettle();
      expect((await repository.selectAll()).single.note, 'Retry creation');
      expect(find.text('Audit root'), findsOneWidget);
    },
  );

  testWidgets('RG10 intentional equal drafts in separate forms both persist', (
    tester,
  ) async {
    for (var index = 0; index < 2; index++) {
      await open(tester, null);
      await tester.enterText(find.byType(TextField).first, '10');
      await tester.enterText(find.byType(TextField).last, 'Intentional repeat');
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD TRANSACTION'));
      await tester.pumpAndSettle();
      expect(find.text('Audit root'), findsOneWidget);
    }
    expect(
      await repository.selectAll(label: 'Intentional repeat'),
      hasLength(2),
    );
  });

  testWidgets(
    'RG10 completing after the form is popped cannot pop the next route',
    (tester) async {
      repository.insertGate = Completer<void>();
      await open(tester, null);
      await tester.enterText(find.byType(TextField).first, '10');
      await tester.enterText(find.byType(TextField).last, 'Away');
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD TRANSACTION'));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Other route')),
        ),
      );
      await tester.pumpAndSettle();
      repository.insertGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Other route'), findsOneWidget);
      expect(await repository.selectAll(label: 'Away'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'RG09 confirmed write still closes the form when projection refresh fails',
    (tester) async {
      await open(tester, null);
      await tester.enterText(find.byType(TextField).first, '10');
      await tester.enterText(
        find.byType(TextField).last,
        'Persisted despite refresh',
      );
      await tester.pumpAndSettle();
      repository.failProjection = true;
      await tester.tap(find.text('ADD TRANSACTION'));
      await tester.pumpAndSettle();
      expect(find.text('Audit root'), findsOneWidget);
      final rows = await harness.db.query(
        'transaction',
        where: 'note = ?',
        whereArgs: ['Persisted despite refresh'],
      );
      expect(rows, hasLength(1));
    },
  );

  testWidgets('RG10 ignored INSERT is not reported as a saved transaction', (
    tester,
  ) async {
    await harness.db.execute(
      "CREATE TRIGGER ignore_insert BEFORE INSERT ON 'transaction' BEGIN SELECT RAISE(IGNORE); END",
    );
    await open(tester, null);
    await tester.enterText(find.byType(TextField).first, '10');
    await tester.enterText(find.byType(TextField).last, 'Ignored');
    await tester.pumpAndSettle();
    await tester.tap(find.text('ADD TRANSACTION'));
    await tester.pumpAndSettle();
    expect(find.byType(CreateTransactionPage), findsOneWidget);
    expect(await harness.db.query('transaction'), isEmpty);
  });

  testWidgets(
    'RG10 provider invalidation during a known committed save cannot offer duplicate retry',
    (tester) async {
      repository.insertGate = Completer<void>();
      repository.insertEntered = Completer<void>();
      await open(tester, null);
      await tester.enterText(find.byType(TextField).first, '10');
      await tester.enterText(
        find.byType(TextField).last,
        'Invalidated during save',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD TRANSACTION'));
      await tester.pump();
      expect(repository.insertEntered!.isCompleted, isTrue);
      container.invalidate(transactionsProvider);
      repository.insertGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Audit root'), findsOneWidget);
      expect(
        await harness.db.query(
          'transaction',
          where: 'note = ?',
          whereArgs: ['Invalidated during save'],
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'RG09 ignored UPDATE keeps the editor open instead of reporting success',
    (tester) async {
      final original = await existing();
      await harness.db.execute(
        "CREATE TRIGGER ignore_update BEFORE UPDATE ON 'transaction' BEGIN SELECT RAISE(IGNORE); END",
      );
      await open(tester, original);
      await tester.enterText(find.byType(TextField).last, 'Ignored update');
      await tester.tap(find.text('UPDATE TRANSACTION'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateTransactionPage), findsOneWidget);
      expect((await repository.selectById(original.id!)).note, 'Before');
    },
  );
  RecurringTransaction schedule() => RecurringTransaction(
    fromDate: now,
    amount: 10,
    note: 'Schedule',
    recurrency: Recurrence.monthly,
    idCategory: categoryId,
    type: TransactionType.expense,
    idBankAccount: 1,
    createdAt: now,
    updatedAt: now,
  );

  for (final attachExisting in [false, true]) {
    test(
      'RG09 recurring schedule and ${attachExisting ? 'attached' : 'initial'} movement roll back together',
      () async {
        final recurring = RecurringTransactionRepository(
          database: _Database(harness.db),
        );
        final movement = attachExisting
            ? await existing()
            : Transaction(
                date: now,
                amount: 10,
                type: TransactionType.expense,
                idBankAccount: 1,
                idCategory: categoryId,
                note: 'Initial',
                recurring: false,
                createdAt: now,
                updatedAt: now,
              );
        final operation = attachExisting ? 'UPDATE' : 'INSERT';
        await harness.db.execute(
          "CREATE TRIGGER fail_initial BEFORE $operation ON 'transaction' BEGIN SELECT RAISE(ABORT, 'synthetic movement failure'); END",
        );
        await expectLater(
          recurring.insertWithTransaction(
            schedule(),
            firstTransaction: movement,
          ),
          throwsA(isA<DatabaseException>()),
        );
        expect(await harness.db.query('recurringTransaction'), isEmpty);
        expect(
          await harness.db.query('transaction'),
          hasLength(attachExisting ? 1 : 0),
        );
        if (attachExisting) {
          expect(
            (await repository.selectById(movement.id!)).recurring,
            isFalse,
          );
        }
        await harness.db.execute('DROP TRIGGER fail_initial');
        final created = await recurring.insertWithTransaction(
          schedule(),
          firstTransaction: movement,
        );
        final saved = (await repository.selectAll()).single;
        expect(saved.idRecurringTransaction, created.id);
        expect(saved.recurring, isTrue);
        expect(await harness.db.query('recurringTransaction'), hasLength(1));
        expect(await harness.db.query('transaction'), hasLength(1));
      },
    );
  }

  for (final ignored in ['recurringTransaction', 'transaction']) {
    test(
      'RG09 ignored $ignored write cannot leave a partial recurring creation',
      () async {
        await harness.db.execute(
          "CREATE TRIGGER ignore_recurring BEFORE INSERT ON '$ignored' BEGIN SELECT RAISE(IGNORE); END",
        );
        final recurring = RecurringTransactionRepository(
          database: _Database(harness.db),
        );
        await expectLater(
          recurring.insertWithTransaction(
            schedule(),
            firstTransaction: Transaction(
              date: now,
              amount: 10,
              type: TransactionType.expense,
              idBankAccount: 1,
              idCategory: categoryId,
              recurring: false,
              createdAt: now,
              updatedAt: now,
            ),
          ),
          throwsStateError,
        );
        expect(await harness.db.query('recurringTransaction'), isEmpty);
        expect(await harness.db.query('transaction'), isEmpty);
      },
    );
  }

  test(
    'RG09 provider creates a controlled-date initial recurring movement atomically',
    () async {
      final receipt = await container
          .read(recurringTransactionsProvider.notifier)
          .create(10, 'Atomic today', TransactionType.expense, clock: now);
      expect(receipt, isNotNull);
      expect(await harness.db.query('recurringTransaction'), hasLength(1));
      final movement = (await repository.selectAll()).single;
      expect(movement.idRecurringTransaction, receipt!.id);
      expect(movement.note, 'Atomic today');
    },
  );

  test(
    'RG09 provider attaches existing movement without making a duplicate first occurrence',
    () async {
      final movement = await existing();
      final receipt = await container
          .read(recurringTransactionsProvider.notifier)
          .create(
            10,
            'Attached',
            TransactionType.expense,
            existingTransaction: movement,
            clock: now,
          );
      expect(receipt, isNotNull);
      expect(await harness.db.query('transaction'), hasLength(1));
      final saved = await repository.selectById(movement.id!);
      expect(saved.idRecurringTransaction, receipt!.id);
      expect(saved.note, 'Attached');
    },
  );
  test(
    'RG09 committed recurring receipt survives a projection refresh failure',
    () async {
      recurringRepository.failRead = true;
      final receipt = await container
          .read(recurringTransactionsProvider.notifier)
          .create(10, 'Receipt', TransactionType.expense, clock: now);
      expect(receipt, isNotNull);
      expect(await harness.db.query('recurringTransaction'), hasLength(1));
      expect(await harness.db.query('transaction'), hasLength(1));
      expect(container.read(recurringTransactionsProvider).hasError, isTrue);
    },
  );

  test(
    'RG10 recurring provider invalidation cannot hide a confirmed commit',
    () async {
      recurringRepository.gate = Completer<void>();
      recurringRepository.entered = Completer<void>();
      final pending = container
          .read(recurringTransactionsProvider.notifier)
          .create(
            10,
            'Invalidated recurring',
            TransactionType.expense,
            clock: now,
          );
      await recurringRepository.entered!.future;
      container.invalidate(recurringTransactionsProvider);
      recurringRepository.gate!.complete();
      final receipt = await pending;
      expect(receipt, isNotNull);
      expect(await harness.db.query('recurringTransaction'), hasLength(1));
      expect(await harness.db.query('transaction'), hasLength(1));
    },
  );
}
