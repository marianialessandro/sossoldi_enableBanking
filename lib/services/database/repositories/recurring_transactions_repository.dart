import 'dart:developer' as dev;

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' hide Transaction;

import '../../../model/recurring_transaction.dart';
import '../../../model/transaction.dart';
import '../sossoldi_database.dart';

part 'recurring_transactions_repository.g.dart';

@riverpod
RecurringTransactionRepository recurringTransactionRepository(Ref ref) {
  return RecurringTransactionRepository(database: ref.watch(databaseProvider));
}

class RecurringTransactionRepository {
  RecurringTransactionRepository({
    required SossoldiDatabase database,
    DateTime Function()? clock,
  }) : _sossoldiDB = database,
       _clock = clock ?? DateTime.now;

  final SossoldiDatabase _sossoldiDB;
  final DateTime Function() _clock;
  Future<void>? _dailyCheckFlight;
  bool _retryDailyCheck = false;
  DateTime? _dailyCheckInstant;

  Future<RecurringTransaction?> insert(RecurringTransaction item) async {
    try {
      final db = await _sossoldiDB.database;
      final id = await db.insert(recurringTransactionTable, item.toJson());
      return item.copy(id: id);
    } catch (e) {
      dev.log('$e');
    }
    return null;
  }

  Future<RecurringTransaction> selectById(int id) async {
    final db = await _sossoldiDB.database;

    final maps = await db.query(
      recurringTransactionTable,
      columns: RecurringTransactionFields.allFields,
      where: '${RecurringTransactionFields.id} = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return RecurringTransaction.fromJson(maps.first);
    } else {
      throw Exception('ID $id not found');
    }
  }

  Future<List<RecurringTransaction>> selectAll() async {
    final db = await _sossoldiDB.database;

    final orderBy = '${RecurringTransactionFields.createdAt} ASC';

    final result = await db.query(recurringTransactionTable, orderBy: orderBy);

    return result.map((json) => RecurringTransaction.fromJson(json)).toList();
  }

  Future<List<RecurringTransaction>> selectAllActive({DateTime? now}) async {
    final db = await _sossoldiDB.database;

    final orderBy = '${RecurringTransactionFields.createdAt} ASC';

    final result = await db.query(
      recurringTransactionTable,
      orderBy: orderBy,
      where:
          '${RecurringTransactionFields.toDate} IS NULL OR ${RecurringTransactionFields.toDate} > ?',
      whereArgs: [(now ?? _clock()).toIso8601String()],
    );

    return result.map((json) => RecurringTransaction.fromJson(json)).toList();
  }

  Future<int> updateItem(RecurringTransaction item) async {
    final db = await _sossoldiDB.database;

    // You can use `rawUpdate` to write the query in SQL
    return db.update(
      recurringTransactionTable,
      item.toJson(),
      where: '${RecurringTransactionFields.id} = ?',
      whereArgs: [item.id],
    );
  }

  Future<int> deleteById(int id) async {
    final db = await _sossoldiDB.database;

    return await db.delete(
      recurringTransactionTable,
      where: '${RecurringTransactionFields.id} = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteByCategory(int id) async {
    final db = await _sossoldiDB.database;

    return await db.delete(
      recurringTransactionTable,
      where: '${RecurringTransactionFields.idCategory} = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteByAccount(int id) async {
    final db = await _sossoldiDB.database;

    return await db.delete(
      recurringTransactionTable,
      where: '${RecurringTransactionFields.idBankAccount} = ?',
      whereArgs: [id],
    );
  }

  static const _lastCheckKey = 'last_recurring_transactions_check';

  /// Runs [checkRecurringTransactions] at most once per rolling 24-hour period.
  Future<void> dailyCheck(SharedPreferences prefs) {
    final active = _dailyCheckFlight;
    if (active != null) return active;
    final flight = _performDailyCheck(prefs);
    _dailyCheckFlight = flight;
    return flight.whenComplete(() {
      if (identical(_dailyCheckFlight, flight)) _dailyCheckFlight = null;
    });
  }

  Future<void> _performDailyCheck(SharedPreferences prefs) async {
    final now = _clock();
    final rawMarker = prefs.get(_lastCheckKey);
    final lastCheck = rawMarker is String ? DateTime.tryParse(rawMarker) : null;
    if (!_retryDailyCheck && lastCheck != null) {
      final elapsed = now.toUtc().difference(lastCheck.toUtc());
      if (!elapsed.isNegative && elapsed < const Duration(days: 1)) return;
    }
    try {
      _dailyCheckInstant = now;
      try {
        await checkRecurringTransactions();
      } finally {
        _dailyCheckInstant = null;
      }
      _retryDailyCheck = true;
      try {
        final saved = await prefs.setString(
          _lastCheckKey,
          now.toUtc().toIso8601String(),
        );
        if (!saved) {
          throw StateError('Recurring transaction check marker was not saved');
        }
      } catch (_) {
        // SharedPreferences updates its memory cache before the platform write completes.
        await prefs.reload();
        rethrow;
      }
      _retryDailyCheck = false;
    } catch (_) {
      _retryDailyCheck = true;
      rethrow;
    }
  }

  Future<void> checkRecurringTransactions() =>
      _checkRecurringTransactionsAt(_dailyCheckInstant ?? _clock());

  Future<void> _checkRecurringTransactionsAt(DateTime now) async {
    final transactions = await selectAllActive(now: now);
    final db = await _sossoldiDB.database;
    for (final transaction in transactions) {
      await db.transaction((txn) async {
        final id = transaction.id;
        if (id == null) {
          throw StateError('No recurring transaction ID provided');
        }
        final lastTransactionDate =
            await _getLastRecurringTransactionInsertion(txn, id) ??
            transaction.fromDate;
        final entity = transaction.recurrency.entity;
        final entityAmount = transaction.recurrency.amount;
        if (entityAmount <= 0) {
          throw StateError(
            'No positive recurrence amount provided for entity "$entity"',
          );
        }
        await _populateRecurringTransaction(
          txn,
          entity,
          lastTransactionDate,
          transaction,
          entityAmount,
          now,
        );
      });
    }
  }

  Future<DateTime?> _getLastRecurringTransactionInsertion(
    DatabaseExecutor db,
    int tid,
  ) async {
    final result = await db.query(
      transactionTable,
      orderBy: '${TransactionFields.date} DESC',
      where: '${TransactionFields.idRecurringTransaction} = ?',
      whereArgs: [tid],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return Transaction.fromJson(result.first).date;
  }

  Future<void> populateRecurringTransaction(
    String scope,
    DateTime lastTransactionDate,
    RecurringTransaction transaction,
    int amount, {
    DateTime? now,
  }) async {
    if (amount == 0) {
      throw Exception('No amount provided for entity "$scope"');
    }

    final db = await _sossoldiDB.database;
    final currentTime = now ?? _clock();
    await db.transaction(
      (txn) => _populateRecurringTransaction(
        txn,
        scope,
        lastTransactionDate,
        transaction,
        amount,
        currentTime,
      ),
    );
  }

  Future<void> _populateRecurringTransaction(
    DatabaseExecutor db,
    String scope,
    DateTime lastTransactionDate,
    RecurringTransaction transaction,
    int amount,
    DateTime currentTime,
  ) async {
    if (amount <= 0) throw StateError('No positive recurrence amount provided');

    // create a list to store the months
    List<DateTime> transactions2Add = [];

    // calculate the number of periods between the current date and the last transaction insertion
    int periods;

    switch (scope) {
      case 'days':
        periods = (currentTime.difference(lastTransactionDate).inDays / amount)
            .floor();
        break;
      case 'months':
        periods =
            (((currentTime.year - lastTransactionDate.year) * 12 +
                        currentTime.month -
                        lastTransactionDate.month) /
                    amount)
                .floor();
        break;
      default:
        throw Exception('No scope provided');
    }

    // for each period passed, insert a new transaction
    for (int i = 0; i < periods; i++) {
      switch (scope) {
        case 'days':
          lastTransactionDate = DateTime(
            lastTransactionDate.year,
            lastTransactionDate.month,
            lastTransactionDate.day + amount,
          );
          break;
        case 'months':
          // get the last day of the next period
          final int lastDayOfNextPeriod = DateTime(
            lastTransactionDate.year,
            (lastTransactionDate.month + amount + 1),
            0,
          ).day;
          int dayOfInsertion = transaction.fromDate.day;

          // if the next period's month has fewer days than the day of the last transaction insertion, adjust the day
          if (transaction.fromDate.day > lastDayOfNextPeriod) {
            dayOfInsertion = lastDayOfNextPeriod;
          }

          lastTransactionDate = DateTime(
            lastTransactionDate.year,
            lastTransactionDate.month + amount,
            dayOfInsertion,
          );

          break;
        default:
          //nothing to do
          return;
      }

      if ((transaction.toDate?.isAfter(lastTransactionDate) ?? true) &&
          lastTransactionDate.isBefore(currentTime)) {
        transactions2Add.add(lastTransactionDate);
      }
    }

    for (var tr in transactions2Add) {
      // insert a new transaction
      Transaction addTr = Transaction(
        date: tr,
        amount: transaction.amount,
        type: transaction.type,
        note: transaction.note,
        idCategory: transaction.idCategory,
        idBankAccount: transaction.idBankAccount,
        recurring: true,
        idRecurringTransaction: transaction.id,
        createdAt: currentTime,
        updatedAt: currentTime,
      );
      await db.insert(transactionTable, addTr.toJson());
      final changed = await db.rawQuery('SELECT changes() AS affected');
      if (changed.single['affected'] != 1) {
        throw StateError('Recurring movement was not inserted');
      }
    }

    // update the last insertion date
    final changed = await db.update(
      recurringTransactionTable,
      transaction.copy(lastInsertion: currentTime).toJson(),
      where: '${RecurringTransactionFields.id} = ?',
      whereArgs: [transaction.id],
    );
    if (changed != 1) throw StateError('Recurring progress was not updated');
  }
}
