// ignore_for_file: file_names

import 'package:sqflite/sqflite.dart';

import '../migration_base.dart';

class AddBankSyncIntegrity extends Migration {
  AddBankSyncIntegrity()
    : super(
        version: 9,
        description: 'Add exact bank ledger and atomic sync checkpoints',
      );

  @override
  Future<void> up(Database db) async {
    await db.execute('ALTER TABLE bankAccount ADD COLUMN currencyCode TEXT');
    await db.execute('''
      CREATE TABLE bankSyncState (
        accountId INTEGER PRIMARY KEY,
        currency TEXT NOT NULL,
        revision INTEGER NOT NULL DEFAULT 0,
        checkpoint TEXT,
        completedAt TEXT,
        historyFrom TEXT,
        historyThrough TEXT,
        strategy TEXT NOT NULL,
        balanceMinor TEXT,
        balanceAt TEXT,
        openingMinor TEXT,
        projectedOpening REAL,
        requiredPsuHeaders TEXT NOT NULL DEFAULT '[]'
      )
    ''');
    await db.execute('''
      CREATE TABLE bankRemoteTransaction (
        accountId INTEGER NOT NULL,
        remoteKey TEXT NOT NULL,
        entryReference TEXT,
        remoteTransactionId TEXT,
        remoteStatus TEXT NOT NULL,
        currency TEXT NOT NULL,
        amountMinor TEXT NOT NULL,
        projectedAmount REAL NOT NULL,
        bankDate TEXT NOT NULL,
        bankNote TEXT NOT NULL,
        localTransactionId INTEGER UNIQUE,
        localDeleted INTEGER NOT NULL DEFAULT 0,
        noteOverridden INTEGER NOT NULL DEFAULT 0,
        localNote TEXT,
        localCategory INTEGER,
        PRIMARY KEY (accountId, remoteKey)
      )
    ''');
    await db.execute('''
      CREATE TABLE bankSyncAudit (
        accountId INTEGER PRIMARY KEY,
        status TEXT NOT NULL,
        rejected INTEGER NOT NULL,
        warnings TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TRIGGER bank_note_override AFTER UPDATE OF note, idCategory ON "transaction"
      BEGIN
        UPDATE bankRemoteTransaction SET
          noteOverridden = CASE WHEN NEW.note IS NOT OLD.note AND NEW.note IS NOT bankNote THEN 1 ELSE noteOverridden END,
          localNote = CASE WHEN NEW.note IS NOT OLD.note AND NEW.note IS NOT bankNote THEN NEW.note ELSE localNote END,
          localCategory = NEW.idCategory
        WHERE localTransactionId = NEW.id;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER bank_local_deletion AFTER DELETE ON "transaction"
      BEGIN
        UPDATE bankRemoteTransaction SET
          localDeleted = CASE WHEN remoteStatus = 'BOOK' THEN 1 ELSE localDeleted END,
          localTransactionId = NULL
        WHERE localTransactionId = OLD.id;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER bank_financial_fields BEFORE UPDATE OF amount, date, type, idBankAccount, idBankAccountTransfer ON "transaction"
      WHEN EXISTS (
        SELECT 1 FROM bankRemoteTransaction b
        WHERE b.localTransactionId = OLD.id AND (
          NEW.amount IS NOT b.projectedAmount OR NEW.date IS NOT b.bankDate
          OR NEW.idBankAccount IS NOT b.accountId OR NEW.idBankAccountTransfer IS NOT NULL
          OR NEW.type IS NOT CASE WHEN substr(b.amountMinor, 1, 1) = '-' THEN 'OUT' ELSE 'IN' END
        )
      )
      BEGIN
        SELECT RAISE(ABORT, 'Bank financial fields are read-only');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER bank_opening_balance BEFORE UPDATE OF startingValue ON bankAccount
      WHEN EXISTS (SELECT 1 FROM bankSyncState WHERE accountId = OLD.id AND projectedOpening IS NOT NEW.startingValue)
      BEGIN
        SELECT RAISE(ABORT, 'Bank opening balance is managed by synchronization');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER bank_global_currency BEFORE UPDATE OF mainCurrency, code ON currency
      WHEN NEW.mainCurrency = 1 AND EXISTS (SELECT 1 FROM bankSyncState WHERE currency != NEW.code)
      BEGIN
        SELECT RAISE(ABORT, 'Imported bank data requires its original global currency');
      END
    ''');
    await db.execute('''
      CREATE TRIGGER bank_global_currency_insert BEFORE INSERT ON currency
      WHEN NEW.mainCurrency = 1 AND EXISTS (SELECT 1 FROM bankSyncState WHERE currency != NEW.code)
      BEGIN
        SELECT RAISE(ABORT, 'Imported bank data requires its original global currency');
      END
    ''');
  }
}
