import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../model/bank_account.dart';
import '../../../model/category_transaction.dart';
import '../../../model/recurring_transaction.dart';
import '../../../model/transaction.dart';
import '../sossoldi_database.dart';

part 'account_repository.g.dart';

@Riverpod(keepAlive: true)
AccountRepository accountRepository(Ref ref) {
  return AccountRepository(database: ref.watch(databaseProvider));
}

class AccountRepository {
  AccountRepository({required SossoldiDatabase database})
    : _sossoldiDB = database;

  final SossoldiDatabase _sossoldiDB;

  final orderByASC = '"${BankAccountFields.order}" ASC';

  Future<BankAccount> insert(BankAccount item) async {
    final db = await _sossoldiDB.database;

    return db.transaction((txn) async {
      await changeMainAccount(txn, item);
      final result = await txn.rawQuery(
        'SELECT COUNT(*) AS count FROM $bankAccountTable',
      );
      final nextOrder = result.first['count'] as int;
      final newItem = item.copy(order: nextOrder);
      final id = await txn.insert(bankAccountTable, newItem.toJson());
      final changed = await txn.rawQuery('SELECT changes() AS affected');
      if (changed.single['affected'] != 1) {
        throw StateError('The account was not inserted');
      }
      return newItem.copy(id: id);
    });
  }

  Future<BankAccount> selectById(int id) async {
    final db = await _sossoldiDB.database;

    final maps = await db.query(
      bankAccountTable,
      columns: BankAccountFields.allFields,
      where: '${BankAccountFields.id} = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return BankAccount.fromJson(maps.first);
    } else {
      throw Exception('ID $id not found');
    }
  }

  Future<BankAccount?> selectMain() async {
    final db = await _sossoldiDB.database;

    final maps = await db.query(
      bankAccountTable,
      columns: BankAccountFields.allFields,
      where: '${BankAccountFields.mainAccount} = ?',
      whereArgs: [1],
    );

    if (maps.isNotEmpty) {
      return BankAccount.fromJson(maps.first);
    } else {
      return null;
    }
  }

  Future<List<BankAccount>> selectAll({bool? active, bool? deleted}) async {
    final db = await _sossoldiDB.database;

    String where = "1 = 1";
    if (active != null) {
      where += ' AND ${BankAccountFields.active} = ${active ? 1 : 0}';
    }
    if (deleted != null) {
      where +=
          ' AND ${BankAccountFields.deletedAt} IS ${deleted ? 'NOT ' : ''}NULL';
    }

    final result = await db.rawQuery('''
      SELECT b.*, (b.${BankAccountFields.startingValue} +
      SUM(CASE WHEN t.${TransactionFields.type} = 'IN' AND t.${TransactionFields.idBankAccount} = b.${BankAccountFields.id} OR t.${TransactionFields.type} = 'TRSF' AND t.${TransactionFields.idBankAccountTransfer} = b.${BankAccountFields.id} THEN t.${TransactionFields.amount}
               ELSE 0 END) -
      SUM(CASE WHEN t.${TransactionFields.type} = 'OUT' AND t.${TransactionFields.idBankAccount} = b.${BankAccountFields.id} OR t.${TransactionFields.type} = 'TRSF' AND t.${TransactionFields.idBankAccount} = b.${BankAccountFields.id} THEN t.${TransactionFields.amount}
               ELSE 0 END)
    ) as ${BankAccountFields.total}
      FROM $bankAccountTable as b
      LEFT JOIN "$transactionTable" as t
             ON (t.${TransactionFields.idBankAccount} = b.${BankAccountFields.id} OR
                 t.${TransactionFields.idBankAccountTransfer} = b.${BankAccountFields.id})
      WHERE $where
      GROUP BY b.${BankAccountFields.id}
      ORDER BY $orderByASC
    ''');

    return result.map((json) => BankAccount.fromJson(json)).toList();
  }

  Future<List<BankAccount>> selectFrequentAccounts() async {
    final db = await _sossoldiDB.database;
    // Select the last 100 transactions, group by account and return the top 5 most used accounts ordered by usage count desc.
    final result = await db.rawQuery('''
        SELECT b.*
        FROM "$bankAccountTable" b
        JOIN (
          SELECT * FROM "$transactionTable"
          ORDER BY "${TransactionFields.date}" DESC
          LIMIT 100
        ) t ON t."${TransactionFields.idBankAccount}" = b."${BankAccountFields.id}" OR t."${TransactionFields.idBankAccountTransfer}" = b."${BankAccountFields.id}"
        WHERE b."${BankAccountFields.active}" = 1 AND ${BankAccountFields.deletedAt} IS NULL
        GROUP BY b."${BankAccountFields.id}"
        ORDER BY COUNT(t."${TransactionFields.id}") DESC
        LIMIT 5
      ''');

    return result.map((json) => BankAccount.fromJson(json)).toList();
  }

  Future<int> updateItem(BankAccount item) async {
    final db = await _sossoldiDB.database;

    return db.transaction((txn) async {
      final existing = await txn.query(
        bankAccountTable,
        columns: [BankAccountFields.id],
        where: '${BankAccountFields.id} = ?',
        whereArgs: [item.id],
        limit: 1,
      );
      if (existing.isEmpty) return 0;
      await changeMainAccount(txn, item);
      final changed = await txn.update(
        bankAccountTable,
        item.toJson(update: true),
        where: '${BankAccountFields.id} = ?',
        whereArgs: [item.id],
      );
      if (changed != 1) throw StateError('The account was not updated');
      return changed;
    });
  }

  // Demote other main accounts through the same executor as the caller's write.
  Future<void> changeMainAccount(DatabaseExecutor db, BankAccount item) async {
    if (!item.mainAccount) return;
    final where = item.id == null
        ? '${BankAccountFields.mainAccount} = ?'
        : '${BankAccountFields.mainAccount} = ? AND ${BankAccountFields.id} != ?';
    final args = <Object?>[1, if (item.id != null) item.id];
    await db.update(
      bankAccountTable,
      {
        BankAccountFields.mainAccount: 0,
        BankAccountFields.updatedAt: DateTime.now().toIso8601String(),
      },
      where: where,
      whereArgs: args,
    );
    final remaining = await db.query(
      bankAccountTable,
      columns: [BankAccountFields.id],
      where: where,
      whereArgs: args,
    );
    if (remaining.isNotEmpty) {
      throw StateError('The previous main account was not updated');
    }
  }

  Future<void> deleteById(BankAccount item) async {
    final db = await _sossoldiDB.database;

    await db.update(
      bankAccountTable,
      item.toJson(delete: true),
      where: '${BankAccountFields.id} = ?',
      whereArgs: [item.id],
    );

    await db.delete(
      recurringTransactionTable,
      where: '${RecurringTransactionFields.idBankAccount} = ?',
      whereArgs: [item.id],
    );

    await normalizeOrders();
  }

  Future<void> updateOrders(List<BankAccount> items) async {
    final db = await _sossoldiDB.database;

    await db.transaction((txn) async {
      for (int i = 0; i < items.length; i++) {
        await txn.update(
          bankAccountTable,
          {BankAccountFields.order: i},
          where: '${BankAccountFields.id} = ?',
          whereArgs: [items[i].id],
        );
      }
    });
  }

  Future<void> normalizeOrders() async {
    final db = await _sossoldiDB.database;

    final result = await db.query(
      bankAccountTable,
      columns: [BankAccountFields.id],
      orderBy: orderByASC,
    );

    for (int i = 0; i < result.length; i++) {
      await db.update(
        bankAccountTable,
        {BankAccountFields.order: i},
        where: '${BankAccountFields.id} = ?',
        whereArgs: [result[i][BankAccountFields.id]],
      );
    }
  }

  Future<int> deactivateById(int id) async {
    final db = await _sossoldiDB.database;

    return await db.update(
      bankAccountTable,
      {BankAccountFields.active: 0, BankAccountFields.mainAccount: 0},
      where: '${BankAccountFields.id} = ?',
      whereArgs: [id],
    );
  }

  Future<num?> getAccountSum(int? id) async {
    final db = await _sossoldiDB.database;

    // get account infos first
    final result = await db.query(
      bankAccountTable,
      where: '${BankAccountFields.id}  = $id',
      limit: 1,
    );
    final singleObject = result.isNotEmpty ? result[0] : null;

    if (singleObject != null) {
      num balance = singleObject[BankAccountFields.startingValue] as num;

      // get all transactions of that account
      final transactionsResult = await db.query(
        transactionTable,
        where:
            '${TransactionFields.idBankAccount}  = $id OR ${TransactionFields.idBankAccountTransfer} = $id',
      );

      for (var transaction in transactionsResult) {
        num amount = transaction[TransactionFields.amount] as num;

        switch (transaction[TransactionFields.type]) {
          case ('IN'):
            if (transaction[TransactionFields.idBankAccount] == id) {
              balance += amount;
            }
            break;
          case ('OUT'):
            if (transaction[TransactionFields.idBankAccount] == id) {
              balance -= amount;
            }
            break;
          case ('TRSF'):
            if (transaction[TransactionFields.idBankAccount] == id) {
              balance -= amount;
            }
            if (transaction[TransactionFields.idBankAccountTransfer] == id) {
              balance += amount;
            }
            break;
        }
      }

      return balance;
    } else {
      return 0;
    }
  }

  Future<List> getTransactions(int accountId, int numTransactions) async {
    final db = await _sossoldiDB.database;

    final accountFilter = "${TransactionFields.idBankAccount} = $accountId";

    final resultQuery = await db.rawQuery('''
      SELECT t.*, EXISTS(SELECT 1 FROM bankRemoteTransaction br WHERE br.localTransactionId = t.id) AS bankImported,
        c.${CategoryTransactionFields.name} as ${TransactionFields.categoryName},
        c.${CategoryTransactionFields.color} as ${TransactionFields.categoryColor},
        c.${CategoryTransactionFields.symbol} as ${TransactionFields.categorySymbol}
      FROM
        "$transactionTable" as t
      LEFT JOIN
        $categoryTransactionTable as c ON t.${TransactionFields.idCategory} = c.${CategoryTransactionFields.id}
      WHERE
        $accountFilter
      ORDER BY
        ${TransactionFields.date} DESC
        LIMIT
          $numTransactions
    ''');

    return resultQuery;
  }

  Future<List> accountDailyBalance(
    int accountId, {
    DateTime? dateRangeStart,
    DateTime? dateRangeEnd,
  }) async {
    final db = await _sossoldiDB.database;

    final accountFilter =
        "(${TransactionFields.idBankAccount} = $accountId OR ${TransactionFields.idBankAccountTransfer} = $accountId)";
    final periodFilterEnd = dateRangeEnd != null
        ? "strftime('%Y-%m-%d', ${TransactionFields.date}) < '${dateRangeEnd.toString().substring(0, 10)}'"
        : "";
    final filters = [periodFilterEnd, accountFilter];
    final sqlFilters = filters.where((filter) => filter != "").join(" AND ");

    final resultQuery = await db.rawQuery('''
      SELECT
        strftime('%Y-%m-%d', ${TransactionFields.date}) as day,
        SUM(CASE WHEN ((${TransactionFields.type} = 'IN' AND ${TransactionFields.idBankAccount} = $accountId) OR (${TransactionFields.type} = 'TRSF' AND ${TransactionFields.idBankAccountTransfer} = $accountId)) THEN ${TransactionFields.amount} ELSE 0 END) as income,
        SUM(CASE WHEN (${TransactionFields.type} = 'OUT' AND ${TransactionFields.idBankAccount} = $accountId) OR (${TransactionFields.type} = 'TRSF' AND ${TransactionFields.idBankAccount} = $accountId) THEN ${TransactionFields.amount} ELSE 0 END) as expense
      FROM "$transactionTable"
      WHERE $sqlFilters
      GROUP BY day
    ''');

    final statritngValue = await db.rawQuery('''
      SELECT ${BankAccountFields.startingValue} as Value
      FROM $bankAccountTable
      WHERE ${BankAccountFields.id} = $accountId
    ''');

    double runningTotal = statritngValue[0]['Value'] as double;

    var result = resultQuery.map((e) {
      runningTotal +=
          double.parse(e['income'].toString()) -
          double.parse(e['expense'].toString());
      return {"day": e["day"], "balance": runningTotal};
    }).toList();

    if (dateRangeStart != null) {
      return result
          .where(
            (element) => dateRangeStart.isBefore(
              DateTime.parse(
                element["day"].toString(),
              ).add(const Duration(days: 1)),
            ),
          )
          .toList();
    }

    return result;
  }

  Future<List> accountMonthlyBalance(
    int accountId, {
    DateTime? dateRangeStart,
    DateTime? dateRangeEnd,
  }) async {
    final db = await _sossoldiDB.database;

    final accountFilter =
        "(${TransactionFields.idBankAccount} = $accountId OR ${TransactionFields.idBankAccountTransfer} = $accountId)";
    final periodFilterEnd = dateRangeEnd != null
        ? "strftime('%Y-%m-%d', ${TransactionFields.date}) < '${dateRangeEnd.toString().substring(0, 10)}'"
        : "";
    final filters = [periodFilterEnd, accountFilter];
    final sqlFilters = filters.where((filter) => filter != "").join(" AND ");

    final resultQuery = await db.rawQuery('''
      SELECT
        strftime('%Y-%m', ${TransactionFields.date}) as month,
        SUM(CASE WHEN ((${TransactionFields.type} = 'IN' AND ${TransactionFields.idBankAccount} = $accountId) OR (${TransactionFields.type} = 'TRSF' AND ${TransactionFields.idBankAccountTransfer} = $accountId)) THEN ${TransactionFields.amount} ELSE 0 END) as income,
        SUM(CASE WHEN (${TransactionFields.type} = 'OUT' AND ${TransactionFields.idBankAccount} = $accountId) OR (${TransactionFields.type} = 'TRSF' AND ${TransactionFields.idBankAccount} = $accountId) THEN ${TransactionFields.amount} ELSE 0 END) as expense
      FROM "$transactionTable"
      WHERE $sqlFilters
      GROUP BY month
    ''');

    final statritngValue = await db.rawQuery('''
      SELECT ${BankAccountFields.startingValue} as Value
      FROM $bankAccountTable
      WHERE ${BankAccountFields.id} = $accountId
    ''');

    double runningTotal = statritngValue[0]['Value'] as double;

    var result = resultQuery.map((e) {
      runningTotal +=
          double.parse(e['income'].toString()) -
          double.parse(e['expense'].toString());
      return {"month": e["month"], "balance": runningTotal};
    }).toList();

    if (dateRangeStart != null) {
      return result
          .where(
            (element) => dateRangeStart.isBefore(
              DateTime.parse(
                ("${element["month"]}-01").toString(),
              ).add(const Duration(days: 1)),
            ),
          )
          .toList();
    }

    return result;
  }
}
