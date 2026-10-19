import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  final manager = MigrationManager();
  late Directory dir;
  late String path;
  Database? opened;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('note-upgrade-');
    path = '${dir.path}/test.db';
  });
  tearDown(() async {
    await opened?.close();
    await dir.delete(recursive: true);
  });
  Future<Database> create(int version, {bool legacy = false}) async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (db, version) async {
          await manager.migrate(db, 0, version);
          if (legacy) {
            for (final sql
                in (jsonDecode(
                          File(
                            'test/fixtures/bank_sync_v9_schema.json',
                          ).readAsStringSync(),
                        )
                        as List)
                    .cast<String>()) {
              await db.execute(sql);
            }
          }
        },
      ),
    );
    opened = db;
    return db;
  }

  Future<void> seed(
    Database db, {
    bool ledger = true,
    String? note = 'Personal',
    String bank = 'Bank',
    String? local = 'Personal',
    int deleted = 0,
    String status = 'BOOK',
  }) async {
    await db.insert('bankConnection', {
      'id': 1,
      'providerId': 'enable_banking',
      'aspspName': 'Synthetic',
      'aspspCountry': 'IT',
      'applicationId': 'app',
      'sessionId': 'session',
      'status': 'ACTIVE',
      'createdAt': '2028-02-29',
      'updatedAt': '2028-02-29',
    });
    await db.insert('bankAccount', {
      'id': 1,
      'name': 'Synthetic',
      'symbol': 'wallet',
      'color': 1,
      'startingValue': 305.89,
      'active': 1,
      'countNetWorth': 1,
      'mainAccount': 0,
      'position': 0,
      'ebConnectionId': 1,
      'ebAccountUid': 'uid',
      'createdAt': '2028-02-29',
      'updatedAt': '2028-02-29',
    });
    await db.insert('transaction', {
      'id': 1,
      'idBankAccount': 1,
      'amount': 73.14,
      'type': 'OUT',
      'date': '2028-02-28',
      'note': note,
      'idCategory': 42,
      'recurring': 0,
      'createdAt': '2028-02-29',
      'updatedAt': '2028-02-29',
    });
    if (ledger) {
      await db.insert('bankRemoteTransaction', {
        'accountId': 1,
        'remoteKey': 'ref:one',
        'entryReference': 'one',
        'remoteStatus': status,
        'currency': 'EUR',
        'amountMinor': '-7314',
        'projectedAmount': 73.14,
        'bankDate': '2028-02-28',
        'bankNote': bank,
        'localTransactionId': 1,
        'localDeleted': deleted,
        'noteOverridden': 1,
        'localNote': local,
        'localCategory': 42,
      });
      await db.insert('bankSyncState', {
        'accountId': 1,
        'currency': 'EUR',
        'revision': 3,
        'strategy': 'longest',
        'balanceMinor': '23275',
        'openingMinor': '30589',
        'projectedOpening': 305.89,
      });
    }
  }

  Future<Database> upgrade(Database before) async {
    await before.close();
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onUpgrade: manager.migrate,
      ),
    );
    opened = db;
    return db;
  }

  Future<void> reset(Database db) async {
    await db.update('transaction', {'note': 'Other personal'}, where: 'id = 1');
    await db.update('transaction', {'note': 'Bank'}, where: 'id = 1');
    final row = (await db.query('bankRemoteTransaction')).single;
    expect(row['noteOverridden'], 0);
    expect(row['localNote'], isNull);
    expect(row['localCategory'], 42);
    expect(row['amountMinor'], '-7314');
    expect((await db.query('bankSyncState')).single['openingMinor'], '30589');
    await db.update('transaction', {'note': null}, where: 'id = 1');
    expect(
      (await db.query('bankRemoteTransaction')).single['noteOverridden'],
      1,
    );
    expect(
      (await db.query('bankRemoteTransaction')).single['localNote'],
      isNull,
    );
    await db.update('transaction', {'note': 'Bank'}, where: 'id = 1');
    expect(
      (await db.query('bankRemoteTransaction')).single['noteOverridden'],
      0,
    );
  }

  group('NOTE fresh', () {
    test(
      'registry reaches ten and new trigger resets a real note edit',
      () async {
        expect(manager.latestVersion, 10);
        final db = await create(manager.latestVersion);
        await seed(db);
        await reset(db);
      },
    );
  });
  group('NOTE upgrade', () {
    for (final source in ['v9', 'v8', 'v8legacy']) {
      test(
        '$source upgrade reopen preserves financial rows and five guards',
        () async {
          final before = await create(
            source == 'v9' ? 9 : 8,
            legacy: source == 'v8legacy',
          );
          final hasLedger = source != 'v8';
          await seed(before, ledger: hasLedger);
          final transactions = await before.query('transaction');
          final accounts = await before.query('bankAccount');
          final connections = await before.query('bankConnection');
          final state = hasLedger ? await before.query('bankSyncState') : null;
          final guards = hasLedger
              ? await before.rawQuery(
                  "SELECT name,sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'bank_%' AND name != 'bank_note_override' ORDER BY name",
                )
              : null;
          final db = await upgrade(before);
          expect(await db.getVersion(), 10);
          expect(await db.query('transaction'), transactions);
          expect(await db.query('bankConnection'), connections);
          if (hasLedger) {
            expect(await db.query('bankAccount'), accounts);
            expect(await db.query('bankSyncState'), state);
            expect(
              await db.rawQuery(
                "SELECT name,sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'bank_%' AND name != 'bank_note_override' ORDER BY name",
              ),
              guards,
            );
            expect(guards, hasLength(5));
            await reset(db);
            await expectLater(
              db.update('transaction', {'amount': 100}, where: 'id = 1'),
              throwsA(isA<DatabaseException>()),
            );
            await expectLater(
              db.update('bankAccount', {'startingValue': 0}, where: 'id = 1'),
              throwsA(isA<DatabaseException>()),
            );
          } else {
            expect(
              (await db.query('bankAccount')).single['startingValue'],
              305.89,
            );
            expect(await db.query('bankRemoteTransaction'), isEmpty);
          }
          await db.close();
          opened = await databaseFactoryFfi.openDatabase(
            path,
            options: OpenDatabaseOptions(version: 10),
          );
          expect(await opened!.getVersion(), 10);
          if (hasLedger) await reset(opened!);
        },
      );
    }
    test('upgrade exception rolls back version data and trigger', () async {
      final before = await create(9);
      await seed(before);
      final triggers = await before.rawQuery(
        "SELECT name,sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name",
      );
      final rows = await before.query('bankRemoteTransaction');
      await before.close();
      await expectLater(
        databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 10,
            onUpgrade: (db, old, next) async {
              await manager.migrate(db, old, next);
              throw StateError('controlled rollback');
            },
          ),
        ),
        throwsStateError,
      );
      opened = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(version: 9),
      );
      expect(await opened!.getVersion(), 9);
      expect(await opened!.query('bankRemoteTransaction'), rows);
      expect(
        await opened!.rawQuery(
          "SELECT name,sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name",
        ),
        triggers,
      );
    });
  });
  group('NOTE conservative', () {
    for (final variant in [
      'documented reset',
      'personal null',
      'personal',
      'future coincidence',
      'deleted',
      'cancelled',
    ]) {
      test('backfill $variant changes only demonstrable lost reset', () async {
        final before = await create(9);
        await seed(
          before,
          note: variant == 'personal null'
              ? null
              : variant == 'documented reset' ||
                    variant == 'deleted' ||
                    variant == 'cancelled'
              ? 'Bank'
              : 'Personal',
          local: variant == 'personal null' ? null : 'Personal',
          bank: variant == 'future coincidence' ? 'Personal' : 'Bank',
          deleted: variant == 'deleted' ? 1 : 0,
          status: variant == 'cancelled' ? 'CNCL' : 'BOOK',
        );
        final original = await before.query('bankRemoteTransaction');
        final db = await upgrade(before);
        final row = (await db.query('bankRemoteTransaction')).single;
        if (variant == 'documented reset') {
          expect(row['noteOverridden'], 0);
          expect(row['localNote'], isNull);
        } else {
          expect([row], original);
        }
        final flag = row['noteOverridden'];
        final local = row['localNote'];
        await db.update('transaction', {'idCategory': 43}, where: 'id = 1');
        final category = (await db.query('bankRemoteTransaction')).single;
        expect(category['noteOverridden'], flag);
        expect(category['localNote'], local);
        expect(category['localCategory'], 43);
      });
    }
  });
}
