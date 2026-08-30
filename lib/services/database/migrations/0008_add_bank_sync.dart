// ignore_for_file: file_names

import 'package:sqflite/sqflite.dart';

import '../../../model/bank_account.dart';
import '../../../model/bank_connection.dart';
import '../../../model/transaction.dart';
import '../migration_base.dart';

class AddBankSync extends Migration {
  AddBankSync()
    : super(version: 8, description: 'Add bank connections and sync fields');

  @override
  Future<void> up(Database db) async {
    await db.execute('''
      CREATE TABLE $bankConnectionTable (
        ${BankConnectionFields.id} INTEGER PRIMARY KEY AUTOINCREMENT,
        ${BankConnectionFields.aspspName} TEXT NOT NULL,
        ${BankConnectionFields.aspspCountry} TEXT NOT NULL,
        ${BankConnectionFields.sessionId} TEXT NOT NULL,
        ${BankConnectionFields.validUntil} TEXT NOT NULL,
        ${BankConnectionFields.status} TEXT NOT NULL,
        ${BankConnectionFields.psuType} TEXT,
        ${BankConnectionFields.createdAt} TEXT,
        ${BankConnectionFields.updatedAt} TEXT
      )
      ''');

    // Nullable: existing manual accounts/transactions must stay untouched.
    await db.execute(
      'ALTER TABLE $bankAccountTable ADD COLUMN ${BankAccountFields.ebAccountUid} TEXT',
    );
    await db.execute(
      'ALTER TABLE $bankAccountTable ADD COLUMN ${BankAccountFields.ebConnectionId} INTEGER',
    );
    await db.execute(
      'ALTER TABLE $bankAccountTable ADD COLUMN ${BankAccountFields.iban} TEXT',
    );
    await db.execute(
      'ALTER TABLE $bankAccountTable ADD COLUMN ${BankAccountFields.lastSyncAt} TEXT',
    );

    await db.execute(
      'ALTER TABLE `$transactionTable` ADD COLUMN ${TransactionFields.externalId} TEXT',
    );

    // UNIQUE backstop for dedup; SQLite treats each NULL as distinct, so
    // manual transactions (externalId IS NULL) are unaffected
    await db.execute(
      'CREATE UNIQUE INDEX idx_transaction_external ON `$transactionTable` '
      '(${TransactionFields.idBankAccount}, ${TransactionFields.externalId})',
    );
  }
}
