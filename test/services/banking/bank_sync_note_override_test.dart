import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/bank_sync_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../support/bank_sync_harness.dart';

void main() {
  sqfliteFfiInit();
  late BankSyncHarness h;
  setUp(() async {
    h = BankSyncHarness(databaseFactoryFfi);
    await h.open();
  });
  tearDown(() => h.close());
  Future<Map<String, Object?>> ledger() async =>
      (await h.db.query('bankRemoteTransaction')).single;
  Future<void> edit(Map<String, Object?> changes) async {
    await h.db.update(
      'transaction',
      changes,
      where: 'id = ?',
      whereArgs: [(await h.transactions()).single['id']],
    );
  }

  Future<void> sync(String note) async {
    h.pages = [
      [bankRecord(note: note)],
    ];
    expect((await h.service.syncAccount(1)).completed, isTrue);
    expect((await h.state())['openingMinor'], '30589');
  }

  Future<void> reopen() async {
    await h.db.close();
    h.db = await databaseFactoryFfi.openDatabase(
      h.path,
      options: OpenDatabaseOptions(
        version: MigrationManager().latestVersion,
        onUpgrade: MigrationManager().migrate,
      ),
    );
    h.repository = BankSyncRepository.withDatabase(h.db);
    h.resetService();
  }

  group('NOTE sync', () {
    test(
      'v9 lost reset is observable then upgrade repairs it before projection',
      () async {
        await h.close();
        h = BankSyncHarness(databaseFactoryFfi);
        await h.open(schemaVersion: 9);
        await sync('Synthetic purchase');
        await edit({'note': 'My override', 'idCategory': 42});
        await edit({'note': 'Synthetic purchase'});
        expect(
          (await ledger())['noteOverridden'],
          1,
          reason: 'The v9 trigger demonstrably loses the explicit reset.',
        );
        expect((await ledger())['localNote'], 'My override');
        await reopen();
        expect(await h.db.getVersion(), 10);
        expect((await ledger())['noteOverridden'], 0);
        await sync('Updated bank description');
        expect(
          (await h.transactions()).single['note'],
          'Updated bank description',
        );
        expect((await h.transactions()).single['idCategory'], 42);
      },
    );
    test(
      'A01 resetting local note to bank text removes override across later updates',
      () async {
        await sync('Synthetic purchase');
        await edit({'note': 'My override', 'idCategory': 42});
        await edit({'note': 'Synthetic purchase'});
        expect((await ledger())['noteOverridden'], 0);
        expect((await ledger())['localNote'], isNull);
        await sync('Updated bank description');
        expect(
          (await h.transactions()).single['note'],
          'Updated bank description',
        );
        await reopen();
        await sync('Second bank description');
        expect(
          (await h.transactions()).single['note'],
          'Second bank description',
        );
        expect((await h.transactions()).single['idCategory'], 42);
        expect((await ledger())['localCategory'], 42);
        expect((await ledger())['amountMinor'], '-7314');
        expect((await h.state())['balanceMinor'], '23275');
        expect((await h.state())['revision'], 3);
      },
    );
    for (final personal in <String?>[
      'Personal',
      null,
      'Future bank description',
    ]) {
      test(
        'personal $personal is preserved including null and future coincidence',
        () async {
          await sync('Synthetic purchase');
          await edit({'note': personal, 'idCategory': 42});
          await sync('Future bank description');
          await edit({'idCategory': 43});
          expect((await ledger())['noteOverridden'], 1);
          expect((await ledger())['localNote'], personal);
          await reopen();
          await sync('Different bank description');
          expect((await h.transactions()).single['note'], personal);
          expect((await ledger())['noteOverridden'], 1);
          expect((await ledger())['localNote'], personal);
          expect((await ledger())['localCategory'], 43);
          expect((await h.transactions()).single['idCategory'], 43);
          expect((await ledger())['amountMinor'], '-7314');
        },
      );
    }
    test(
      'category-only does not set override and local deletion stays deleted',
      () async {
        await sync('Synthetic purchase');
        await edit({'idCategory': 42});
        expect((await ledger())['noteOverridden'], 0);
        await sync('Updated bank description');
        expect(
          (await h.transactions()).single['note'],
          'Updated bank description',
        );
        await h.db.delete('transaction');
        await reopen();
        await sync('Another bank description');
        expect(await h.transactions(), isEmpty);
        expect((await ledger())['localDeleted'], 1);
        expect((await ledger())['localCategory'], 42);
      },
    );
    test('reset survives remote correction cancellation and reopen', () async {
      await sync('Synthetic purchase');
      await edit({'note': 'Personal', 'idCategory': 42});
      await edit({'note': 'Synthetic purchase'});
      h.pages = [
        [bankRecord(note: 'Corrected bank note', amount: '70.00')],
      ];
      h.balance = '235.89';
      expect((await h.service.syncAccount(1)).completed, isTrue);
      expect((await ledger())['noteOverridden'], 0);
      expect((await ledger())['amountMinor'], '-7000');
      expect((await h.transactions()).single['note'], 'Corrected bank note');
      expect((await h.transactions()).single['idCategory'], 42);
      h.pages = [
        [
          bankRecord(note: 'Cancelled', amount: '70.00', status: 'CNCL'),
          bankRecord(reference: 'zero', amount: '0.00'),
        ],
      ];
      h.balance = '305.89';
      h.balanceMarker = 'zero';
      expect((await h.service.syncAccount(1)).completed, isTrue);
      await reopen();
      expect((await h.service.syncAccount(1)).completed, isTrue);
      final cancelled = (await h.db.query(
        'bankRemoteTransaction',
        where: 'entryReference = ?',
        whereArgs: ['ref-1'],
      )).single;
      expect(cancelled['localTransactionId'], isNull);
      expect(cancelled['localDeleted'], 0);
      expect(cancelled['noteOverridden'], 0);
      expect(cancelled['localNote'], isNull);
      expect(cancelled['localCategory'], 42);
      expect(await h.transactions(), hasLength(1));
      expect((await h.state())['openingMinor'], '30589');
    });
  });
}
