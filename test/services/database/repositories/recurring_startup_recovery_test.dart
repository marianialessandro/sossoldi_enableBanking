import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sossoldi/model/recurring_transaction.dart';
import 'package:sossoldi/model/transaction.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/recurring_transactions_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

class _Database extends SossoldiDatabase {
  final Database value;
  _Database(this.value);
  @override
  Future<Database> get database async => value;
}

class _MarkerPreferences implements SharedPreferences {
  Object? cached;
  Object? persisted;
  bool failWrites = false;
  bool failReload = false;
  int writes = 0;
  _MarkerPreferences(Object? marker) : cached = marker, persisted = marker;

  @override
  Object? get(String key) => cached;

  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    cached = value;
    if (failWrites) return false;
    persisted = value;
    return true;
  }

  @override
  Future<void> reload() async {
    if (failReload) throw StateError('Synthetic preference reload failure');
    cached = persisted;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  sqfliteFfiInit();
  const marker = 'last_recurring_transactions_check';
  late Directory folder;
  late Database db;
  late RecurringTransactionRepository repository;
  late DateTime now;

  setUp(() async {
    now = DateTime.utc(2032, 4, 1, 12);
    folder = await Directory.systemTemp.createTemp('recurring_startup_');
    final manager = MigrationManager();
    db = await databaseFactoryFfi.openDatabase(
      '${folder.path}/recurring.db',
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onCreate: (db, version) => manager.migrate(db, 0, version),
      ),
    );
    repository = RecurringTransactionRepository(
      database: _Database(db),
      clock: () => now,
    );
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await db.close();
    await folder.delete(recursive: true);
  });

  Future<RecurringTransaction> rent({DateTime? fromDate}) async {
    final item = await repository.insert(
      RecurringTransaction(
        fromDate: fromDate ?? DateTime(now.year, now.month - 3, 1),
        amount: 100,
        note: 'Synthetic recurring rent',
        recurrency: Recurrence.monthly,
        idCategory: 1,
        type: TransactionType.expense,
        idBankAccount: 1,
        createdAt: now,
        updatedAt: now,
      ),
    );
    return item!;
  }

  Future<List<Map<String, Object?>>> generated() =>
      db.query('transaction', orderBy: 'date');

  for (final invalid in <Object?>[
    null,
    '',
    'not-a-date',
    true,
    42,
    <String>['bad'],
  ]) {
    test(
      'RG07-01 malformed marker $invalid permits awaited startup continuation',
      () async {
        SharedPreferences.setMockInitialValues({marker: ?invalid});
        final prefs = await SharedPreferences.getInstance();
        await rent();
        var startupCanContinue = false;
        await repository.dailyCheck(prefs);
        startupCanContinue = true;
        expect(startupCanContinue, isTrue);
        expect((await generated()).length, 3);
        expect(prefs.getString(marker), now.toUtc().toIso8601String());
        await repository.dailyCheck(prefs);
        expect((await generated()).length, 3);
      },
    );
  }

  for (final elapsed in [
    const Duration(
      hours: 23,
      minutes: 59,
      seconds: 59,
      milliseconds: 999,
      microseconds: 999,
    ),
    const Duration(days: 1),
    const Duration(days: 1, microseconds: 1),
  ]) {
    test(
      'RG07-02/03 rolling daily threshold at $elapsed shares one clock',
      () async {
        SharedPreferences.setMockInitialValues({
          marker: now.subtract(elapsed).toUtc().toIso8601String(),
        });
        final prefs = await SharedPreferences.getInstance();
        await rent();
        await repository.dailyCheck(prefs);
        final due = elapsed >= const Duration(days: 1);
        expect((await generated()).length, due ? 3 : 0);
        expect(
          prefs.getString(marker),
          due
              ? now.toUtc().toIso8601String()
              : now.subtract(elapsed).toUtc().toIso8601String(),
        );
      },
    );
  }

  for (final civilDate in [
    DateTime(2032, 3, 28, 12),
    DateTime(2032, 10, 31, 12),
    DateTime(2033, 1, 1, 12),
  ]) {
    test(
      'RG07-03 rolling UTC duration across civil boundary $civilDate',
      () async {
        now = civilDate;
        final before = now.subtract(const Duration(days: 1));
        SharedPreferences.setMockInitialValues({
          marker: before.toUtc().toIso8601String(),
        });
        final prefs = await SharedPreferences.getInstance();
        await rent();
        await repository.dailyCheck(prefs);
        final rows = await generated();
        expect(rows.length, 3);
        final civilDates = rows
            .map((row) => DateTime.parse(row['date'] as String))
            .toList();
        expect(civilDates, [
          for (var offset = -2; offset <= 0; offset++)
            DateTime(now.year, now.month + offset, 1),
        ]);
        expect(prefs.getString(marker), now.toUtc().toIso8601String());
      },
    );
  }

  test(
    'a future marker is repaired rather than skipping maintenance indefinitely',
    () async {
      SharedPreferences.setMockInitialValues({
        marker: now.add(const Duration(days: 5)).toIso8601String(),
      });
      final prefs = await SharedPreferences.getInstance();
      await rent();
      await repository.dailyCheck(prefs);
      expect((await generated()).length, 3);
      expect(prefs.getString(marker), now.toUtc().toIso8601String());
    },
  );

  test(
    'RG07-04 processing failure is propagated without a completed marker and retry resumes saved history',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await rent();
      await db.execute(
        "CREATE TRIGGER reject_march BEFORE INSERT ON 'transaction' WHEN NEW.date LIKE '2032-03-%' BEGIN SELECT RAISE(ABORT, 'synthetic recurring write failure'); END",
      );
      await expectLater(
        repository.dailyCheck(prefs),
        throwsA(isA<DatabaseException>()),
      );
      expect(prefs.get(marker), isNull);
      expect((await generated()).length, 0);
      await db.execute('DROP TRIGGER reject_march');
      await repository.dailyCheck(prefs);
      final rows = await generated();
      expect(rows.length, 3);
      expect(rows.map((row) => row['date']).toSet().length, 3);
      expect(prefs.getString(marker), now.toUtc().toIso8601String());
    },
  );

  test(
    'RG07-04 a failed last-insertion update does not duplicate previously committed movements on retry',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await rent();
      await db.execute(
        "CREATE TRIGGER reject_progress BEFORE UPDATE ON recurringTransaction BEGIN SELECT RAISE(ABORT, 'synthetic progress failure'); END",
      );
      await expectLater(
        repository.dailyCheck(prefs),
        throwsA(isA<DatabaseException>()),
      );
      expect(prefs.get(marker), isNull);
      expect((await generated()).length, 0);
      await db.execute('DROP TRIGGER reject_progress');
      await repository.dailyCheck(prefs);
      expect((await generated()).length, 3);
    },
  );

  for (final ignored in ['movement', 'progress']) {
    test(
      'ignored recurring $ignored write rolls back generated rows and leaves the marker stale',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await rent();
        if (ignored == 'movement') {
          await db.execute(
            "CREATE TRIGGER ignore_work BEFORE INSERT ON 'transaction' WHEN NEW.date LIKE '2032-03-%' BEGIN SELECT RAISE(IGNORE); END",
          );
        } else {
          await db.execute(
            "CREATE TRIGGER ignore_work BEFORE UPDATE ON recurringTransaction BEGIN SELECT RAISE(IGNORE); END",
          );
        }
        await expectLater(repository.dailyCheck(prefs), throwsStateError);
        expect(await generated(), isEmpty);
        expect(prefs.get(marker), isNull);
        await db.execute('DROP TRIGGER ignore_work');
        await repository.dailyCheck(prefs);
        expect((await generated()).length, 3);
        expect(prefs.getString(marker), now.toUtc().toIso8601String());
      },
    );
  }

  test(
    'RG07-04 failed marker write reloads the cache and can retry without duplicate history',
    () async {
      final prefs = _MarkerPreferences(null)..failWrites = true;
      await rent();
      await expectLater(repository.dailyCheck(prefs), throwsStateError);
      expect(prefs.cached, isNull);
      expect(prefs.persisted, isNull);
      expect((await generated()).length, 3);
      prefs.failWrites = false;
      await repository.dailyCheck(prefs);
      expect((await generated()).length, 3);
      expect(prefs.persisted, now.toUtc().toIso8601String());
    },
  );

  test(
    'a marker reload failure remains explicit and never suppresses a later retry',
    () async {
      final prefs = _MarkerPreferences(null)
        ..failWrites = true
        ..failReload = true;
      await rent();
      await expectLater(repository.dailyCheck(prefs), throwsStateError);
      expect((await generated()).length, 3);
      prefs.failWrites = false;
      prefs.failReload = false;
      await repository.dailyCheck(prefs);
      expect(prefs.writes, 2);
      expect((await generated()).length, 3);
    },
  );

  test(
    'overlapping checks on one repository share a single in-flight operation',
    () async {
      final prefs = _MarkerPreferences(null);
      await rent();
      await Future.wait([
        repository.dailyCheck(prefs),
        repository.dailyCheck(prefs),
      ]);
      expect((await generated()).length, 3);
      expect(prefs.writes, 1);
    },
  );

  test(
    'daily selection generation and marker use a single captured instant',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await rent();
      var reads = 0;
      repository = RecurringTransactionRepository(
        database: _Database(db),
        clock: () {
          reads++;
          return reads == 1 ? now : DateTime.utc(2040, 1, 1);
        },
      );
      await repository.dailyCheck(prefs);
      expect(reads, 1);
      expect((await generated()).length, 3);
      expect(prefs.getString(marker), now.toUtc().toIso8601String());
    },
  );

  test(
    'monthly recurrence keeps civil end-of-month dates through leap February',
    () async {
      await rent(fromDate: DateTime(2032, 1, 31));
      await repository.checkRecurringTransactions();
      final dates = (await generated())
          .map((row) => DateTime.parse(row['date'] as String))
          .toList();
      expect(dates.map((date) => '${date.month}-${date.day}'), [
        '2-29',
        '3-31',
      ]);
    },
  );

  test(
    'genuine database read failures remain explicit and do not advance the marker',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await db.execute('DROP TABLE recurringTransaction');
      await expectLater(
        repository.dailyCheck(prefs),
        throwsA(isA<DatabaseException>()),
      );
      expect(prefs.get(marker), isNull);
    },
  );
}
