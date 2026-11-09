import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/transaction.dart' as model;
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/transactions_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Database extends SossoldiDatabase {
  _Database(this.value);
  final Database value;
  @override
  Future<Database> get database async => value;
}

void main() {
  sqfliteFfiInit();
  late Directory temporary;
  late Database db;
  late _Database database;
  final instant = DateTime.utc(2032, 3, 28, 12).toIso8601String();

  Map<String, Object?> movement({int id = 1}) => {
    'id': id,
    'date': instant,
    'amount': 10,
    'type': 'OUT',
    'note': 'Original',
    'idBankAccount': 1,
    'recurring': 0,
    'createdAt': instant,
    'updatedAt': instant,
  };

  Future<Map<String, List<Map<String, Object?>>>> snapshot() async {
    final result = <String, List<Map<String, Object?>>>{};
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%' ORDER BY name",
    );
    for (final table in tables) {
      final name = table['name'] as String;
      result[name] = await db.query(name, orderBy: 'rowid');
    }
    return result;
  }

  Future<String> write(List<Map<String, Object?>> records) async {
    final headers = <String>{
      'table_name',
      ...records.expand((row) => row.keys),
    }.toList();
    final data = [
      headers,
      for (final row in records)
        [for (final header in headers) row[header] ?? ''],
    ];
    final file = File('${temporary.path}/import.csv');
    await file.writeAsString(const ListToCsvConverter().convert(data));
    return file.path;
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'sossoldi_csv_validation_',
    );
    final migrations = MigrationManager();
    db = await databaseFactoryFfi.openDatabase(
      '${temporary.path}/data.db',
      options: OpenDatabaseOptions(
        version: migrations.latestVersion,
        onCreate: (db, version) => migrations.migrate(db, 0, version),
      ),
    );
    database = _Database(db);
    await db.insert('bankAccount', {
      'id': 1,
      'name': 'Original',
      'symbol': 'wallet',
      'color': 0,
      'startingValue': 100,
      'active': 1,
      'countNetWorth': 1,
      'mainAccount': 1,
      'position': 0,
      'createdAt': instant,
      'updatedAt': instant,
    });
    await db.insert('transaction', movement());
  });
  tearDown(() async {
    await db.close();
    await temporary.delete(recursive: true);
  });

  for (final invalid in <String, Map<String, Object?>>{
    'unknown type': {'type': 'BOGUS'},
    'missing date': {'date': null},
    'unparseable date': {'date': 'not-a-date'},
    'overflow date': {'date': '2032-02-30T12:00:00Z'},
    'overflow time': {'date': '2032-03-28T24:00:00Z'},
    'overflow offset hour': {'date': '2032-03-28T12:00:00+99:99'},
    'overflow offset minute': {'date': '2032-03-28T12:00:00+01:99'},
    'text amount': {'amount': 'not-a-number'},
    'NaN amount': {'amount': 'NaN'},
    'infinite amount': {'amount': 'Infinity'},
    'invalid boolean': {'recurring': 2},
    'nonintegral account ID': {'idBankAccount': 1.5},
    'overflow ID': {'id': '9223372036854775808'},
    'underflow ID': {'id': '-9223372036854775809'},
    'overflow exponent ID': {'id': '1e30'},
  }.entries) {
    test(
      'invalid ${invalid.key} is rejected before overwriting any table',
      () async {
        final before = await snapshot();
        final row = {
          'table_name': 'transaction',
          ...movement(id: 777),
          ...invalid.value,
        };
        final path = await write([row]);
        await expectLater(
          database.importFromCSV(path),
          throwsA(isA<FormatException>()),
        );
        expect(await snapshot(), before);
        expect(
          (await TransactionsRepository(
            database: database,
          ).selectAll()).single.note,
          'Original',
        );
      },
    );
  }

  test(
    'an invalid final row leaves an earlier valid table unchanged',
    () async {
      final before = await snapshot();
      final path = await write([
        {
          'table_name': 'bankAccount',
          'id': 2,
          'name': 'Replacement',
          'symbol': 'wallet',
          'color': 0,
          'startingValue': 50,
          'active': 1,
          'mainAccount': 1,
          'createdAt': instant,
          'updatedAt': instant,
        },
        {'table_name': 'transaction', ...movement(id: 777), 'type': 'BOGUS'},
      ]);
      await expectLater(
        database.importFromCSV(path),
        throwsA(isA<FormatException>()),
      );
      expect(await snapshot(), before);
      await db.close();
      db = await databaseFactoryFfi.openDatabase('${temporary.path}/data.db');
      database = _Database(db);
      expect(await snapshot(), before);
    },
  );

  test(
    'valid integers decimals Unicode and quoted multiline notes survive import',
    () async {
      final path = await write([
        {
          'table_name': 'transaction',
          ...movement(id: 2),
          'note': 'Caffè, l\'acqua\nseconda riga',
          'amount': 10,
        },
        {
          'table_name': 'transaction',
          ...movement(id: 3),
          'note': '00123',
          'amount': 0.25,
        },
      ]);
      expect(await database.importFromCSV(path), {'transaction': true});
      final rows = await TransactionsRepository(database: database).selectAll();
      expect(rows.map((row) => row.amount).toList()..sort(), [0.25, 10]);
      expect(
        rows.map((row) => row.note),
        containsAll(['Caffè, l\'acqua\nseconda riga', '00123']),
      );
      expect(
        rows.every((row) => row.type == model.TransactionType.expense),
        isTrue,
      );
    },
  );

  test(
    'exact signed int64 boundaries survive without floating point clamping',
    () async {
      final path = await write([
        {
          'table_name': 'transaction',
          ...movement(),
          'id': '-9223372036854775808',
        },
        {
          'table_name': 'transaction',
          ...movement(),
          'id': '9223372036854775807',
        },
      ]);
      await database.importFromCSV(path);
      final rows = await db.query(
        'transaction',
        columns: ['id'],
        orderBy: 'id',
      );
      expect(rows.map((row) => row['id']), [
        -9223372036854775808,
        9223372036854775807,
      ]);
    },
  );

  test('legacy account file may omit optional and defaulted columns', () async {
    final path = await write([
      {
        'table_name': 'bankAccount',
        'id': 2,
        'name': 'Legacy',
        'symbol': 'wallet',
        'color': 0,
        'startingValue': 10,
        'active': 1,
        'mainAccount': 1,
        'createdAt': instant,
        'updatedAt': instant,
      },
    ]);
    expect(await database.importFromCSV(path), {'bankAccount': true});
    expect((await db.query('bankAccount')).single['position'], 0);
  });
}
