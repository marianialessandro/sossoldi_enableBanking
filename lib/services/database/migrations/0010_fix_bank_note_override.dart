// ignore_for_file: file_names

import 'package:sqflite/sqflite.dart';
import '../migration_base.dart';

class FixBankNoteOverride extends Migration {
  FixBankNoteOverride()
    : super(
        version: 10,
        description: 'Reset explicit bank note overrides conservatively',
      );

  @override
  Future<void> up(Database db) async {
    // Only a projection already restored to the current bank text proves a lost reset.
    await db.execute('''
      UPDATE bankRemoteTransaction SET noteOverridden = 0, localNote = NULL
      WHERE noteOverridden = 1 AND remoteStatus = 'BOOK' AND localDeleted = 0
        AND localNote IS NOT bankNote
        AND EXISTS (
          SELECT 1 FROM "transaction" t
          WHERE t.id = bankRemoteTransaction.localTransactionId
            AND t.idBankAccount = bankRemoteTransaction.accountId
            AND t.note IS bankRemoteTransaction.bankNote
        )
    ''');
    await db.execute('DROP TRIGGER bank_note_override');
    await db.execute('''
      CREATE TRIGGER bank_note_override AFTER UPDATE OF note, idCategory ON "transaction"
      BEGIN
        UPDATE bankRemoteTransaction SET
          noteOverridden = CASE WHEN NEW.note IS NOT OLD.note THEN CASE WHEN NEW.note IS bankNote THEN 0 ELSE 1 END ELSE noteOverridden END,
          localNote = CASE WHEN NEW.note IS NOT OLD.note THEN CASE WHEN NEW.note IS bankNote THEN NULL ELSE NEW.note END ELSE localNote END,
          localCategory = NEW.idCategory
        WHERE localTransactionId = NEW.id;
      END
    ''');
  }
}
