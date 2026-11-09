import 'dart:io';

import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MainAccountTestDatabase extends SossoldiDatabase {
  final Database value;
  MainAccountTestDatabase(this.value);

  @override
  Future<Database> get database async => value;
}

class MainAccountTestHarness {
  late Directory folder;
  late String path;
  late Database db;
  late AccountRepository repository;

  Future<void> open() async {
    sqfliteFfiInit();
    folder = await Directory.systemTemp.createTemp('main_account_integrity_');
    path = '${folder.path}/accounts.db';
    await reopen();
  }

  Future<void> reopen() async {
    final manager = MigrationManager();
    db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onCreate: (db, version) => manager.migrate(db, 0, version),
      ),
    );
    repository = AccountRepository(database: MainAccountTestDatabase(db));
  }

  BankAccount account(String name, {bool main = false}) => BankAccount(
    name: name,
    symbol: 'wallet',
    color: 1,
    startingValue: 100,
    active: true,
    countNetWorth: true,
    mainAccount: main,
    order: 42,
    createdAt: DateTime.utc(2032, 3, 28, 12),
    updatedAt: DateTime.utc(2032, 3, 28, 12),
  );

  Future<void> close() async {
    await db.close();
    await folder.delete(recursive: true);
  }
}
