import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../model/bank_connection.dart';
import '../sossoldi_database.dart';

part 'bank_connection_repository.g.dart';

@Riverpod(keepAlive: true)
BankConnectionRepository bankConnectionRepository(Ref ref) {
  return BankConnectionRepository(database: ref.watch(databaseProvider));
}

class BankConnectionRepository {
  BankConnectionRepository({required SossoldiDatabase database})
    : _sossoldiDB = database;

  final SossoldiDatabase _sossoldiDB;

  Future<BankConnection> insert(BankConnection item) async {
    final db = await _sossoldiDB.database;
    final id = await db.insert(bankConnectionTable, item.toJson());
    return item.copy(id: id);
  }

  Future<BankConnection> selectById(int id) async {
    final db = await _sossoldiDB.database;

    final maps = await db.query(
      bankConnectionTable,
      columns: BankConnectionFields.allFields,
      where: '${BankConnectionFields.id} = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return BankConnection.fromJson(maps.first);
    } else {
      throw Exception('ID $id not found');
    }
  }

  Future<List<BankConnection>> selectAll() async {
    final db = await _sossoldiDB.database;

    final maps = await db.query(
      bankConnectionTable,
      columns: BankConnectionFields.allFields,
      orderBy: '${BankConnectionFields.createdAt} ASC',
    );

    return maps.map((json) => BankConnection.fromJson(json)).toList();
  }

  Future<List<BankConnection>> selectActive() async {
    final db = await _sossoldiDB.database;

    final maps = await db.query(
      bankConnectionTable,
      columns: BankConnectionFields.allFields,
      where: '${BankConnectionFields.status} = ?',
      whereArgs: [BankConnectionStatus.active.code],
    );

    return maps.map((json) => BankConnection.fromJson(json)).toList();
  }

  Future<int> updateItem(BankConnection item) async {
    final db = await _sossoldiDB.database;

    return db.update(
      bankConnectionTable,
      item.toJson(update: true),
      where: '${BankConnectionFields.id} = ?',
      whereArgs: [item.id],
    );
  }

  Future<int> markStatus(int id, BankConnectionStatus status) async {
    final db = await _sossoldiDB.database;

    return db.update(
      bankConnectionTable,
      {
        BankConnectionFields.status: status.code,
        BankConnectionFields.updatedAt: DateTime.now().toIso8601String(),
      },
      where: '${BankConnectionFields.id} = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteById(int id) async {
    final db = await _sossoldiDB.database;

    return db.delete(
      bankConnectionTable,
      where: '${BankConnectionFields.id} = ?',
      whereArgs: [id],
    );
  }
}
