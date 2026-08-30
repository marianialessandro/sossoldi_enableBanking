import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late SossoldiDatabase sossoldiDatabase;
  late AccountRepository accountRepository;
  late BankConnectionRepository bankConnectionRepository;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    sossoldiDatabase = SossoldiDatabase(
      dbName: 'bank_connection_repository_test.db',
    );
    await sossoldiDatabase.database;
  });

  setUp(() async {
    await sossoldiDatabase.clearDatabase();
    accountRepository = AccountRepository(database: sossoldiDatabase);
    bankConnectionRepository = BankConnectionRepository(
      database: sossoldiDatabase,
    );
  });

  tearDownAll(() => sossoldiDatabase.close());

  group('BankConnectionRepository.finalizeDisconnect', () {
    test(
      'unlinks every account fed by the connection and marks it revoked',
      () async {
        final connection = await bankConnectionRepository.insert(
          BankConnection(
            aspspName: 'Test Bank',
            aspspCountry: 'IT',
            sessionId: 'sess-1',
            validUntil: DateTime.now().add(const Duration(days: 90)),
            status: BankConnectionStatus.active,
          ),
        );
        final account1 = await accountRepository.insert(
          BankAccount(
            name: 'Checking',
            symbol: 'payments',
            color: 1,
            startingValue: 0,
            active: true,
            countNetWorth: true,
            mainAccount: false,
            order: 0,
            ebAccountUid: 'acc-1',
            ebConnectionId: connection.id,
            iban: 'IT60X0542811101000000123456',
          ),
        );
        final account2 = await accountRepository.insert(
          BankAccount(
            name: 'Savings',
            symbol: 'payments',
            color: 1,
            startingValue: 0,
            active: true,
            countNetWorth: true,
            mainAccount: false,
            order: 0,
            ebAccountUid: 'acc-2',
            ebConnectionId: connection.id,
          ),
        );
        // A manual account: disconnect must leave it untouched.
        final manualAccount = await accountRepository.insert(
          const BankAccount(
            name: 'Cash',
            symbol: 'wallet',
            color: 0,
            startingValue: 0,
            active: true,
            countNetWorth: true,
            mainAccount: false,
            order: 0,
          ),
        );

        await bankConnectionRepository.finalizeDisconnect(connection.id!);

        final reloaded1 = await accountRepository.selectById(account1.id!);
        expect(reloaded1.ebAccountUid, isNull);
        expect(reloaded1.ebConnectionId, isNull);
        expect(reloaded1.iban, isNull);

        final reloaded2 = await accountRepository.selectById(account2.id!);
        expect(reloaded2.ebAccountUid, isNull);
        expect(reloaded2.ebConnectionId, isNull);

        final reloadedManual = await accountRepository.selectById(
          manualAccount.id!,
        );
        expect(reloadedManual.ebAccountUid, isNull);

        final reloadedConnection = await bankConnectionRepository.selectById(
          connection.id!,
        );
        expect(reloadedConnection.status, BankConnectionStatus.revoked);
      },
    );
  });
}
