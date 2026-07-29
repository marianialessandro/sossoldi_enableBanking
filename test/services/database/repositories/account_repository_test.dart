import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late SossoldiDatabase sossoldiDatabase;
  late AccountRepository accountRepository;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    sossoldiDatabase = SossoldiDatabase(dbName: 'account_repository_test.db');
    await sossoldiDatabase.database;
  });

  setUp(() async {
    await sossoldiDatabase.clearDatabase();
    accountRepository = AccountRepository(database: sossoldiDatabase);
  });

  tearDownAll(() => sossoldiDatabase.close());

  BankAccount linkedAccount({required String name, required String ebUid}) =>
      BankAccount(
        name: name,
        symbol: 'payments',
        color: 1,
        startingValue: 0,
        active: true,
        countNetWorth: true,
        mainAccount: false,
        order: 0,
        ebAccountUid: ebUid,
        ebConnectionId: 1,
      );

  group('AccountRepository.selectLinked', () {
    test('returns an active linked account', () async {
      await accountRepository.insert(
        linkedAccount(name: 'Checking', ebUid: 'acc-1'),
      );

      final linked = await accountRepository.selectLinked();

      expect(linked, hasLength(1));
      expect(linked.single.ebAccountUid, 'acc-1');
    });

    test('excludes a deleted linked account', () async {
      final inserted = await accountRepository.insert(
        linkedAccount(name: 'Checking', ebUid: 'acc-1'),
      );
      // deleteById relies on createdAt already being set, as it always is
      // on an account round-tripped through the DB (insert() itself echoes
      // back the argument it was given, without createdAt).
      final account = await accountRepository.selectById(inserted.id!);

      await accountRepository.deleteById(account);

      expect(await accountRepository.selectLinked(), isEmpty);
    });

    test('excludes a deactivated linked account', () async {
      final account = await accountRepository.insert(
        linkedAccount(name: 'Checking', ebUid: 'acc-1'),
      );

      await accountRepository.deactivateById(account.id!);

      expect(await accountRepository.selectLinked(), isEmpty);
    });
  });
}
