import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../support/main_account_test_harness.dart';

void main() {
  late MainAccountTestHarness h;
  late BankAccount original;

  setUp(() async {
    h = MainAccountTestHarness();
    await h.open();
    original = await h.repository.insert(h.account('Original', main: true));
  });
  tearDown(() => h.close());

  Future<List<Map<String, Object?>>> rows() =>
      h.db.query('bankAccount', orderBy: 'id');

  test(
    'RG03-01 failed main account insert rolls back the demotion and all data',
    () async {
      final before = await rows();
      await h.db.execute(
        "CREATE TRIGGER reject_insert BEFORE INSERT ON bankAccount BEGIN SELECT RAISE(ABORT, 'synthetic insert failure'); END",
      );
      await expectLater(
        h.repository.insert(h.account('Replacement', main: true)),
        throwsA(isA<DatabaseException>()),
      );
      expect(await rows(), before);
      await h.db.close();
      await h.reopen();
      expect(await rows(), before);
      expect((await h.repository.selectMain())?.id, original.id);
      await h.db.execute('DROP TRIGGER reject_insert');
      final replacement = await h.repository.insert(
        h.account('Replacement', main: true),
      );
      expect((await h.repository.selectMain())?.id, replacement.id);
      expect((await rows()).length, 2);
      expect(replacement.order, 1);
    },
  );

  test(
    'RG03-02 failed main account update preserves both original accounts after reopen',
    () async {
      final other = await h.repository.insert(h.account('Other'));
      final before = await rows();
      await h.db.execute(
        "CREATE TRIGGER reject_update BEFORE UPDATE ON bankAccount WHEN NEW.id = ${other.id} BEGIN SELECT RAISE(ABORT, 'synthetic update failure'); END",
      );
      await expectLater(
        h.repository.updateItem(other.copy(mainAccount: true, name: 'Unsaved')),
        throwsA(isA<DatabaseException>()),
      );
      expect(await rows(), before);
      await h.db.close();
      await h.reopen();
      expect(await rows(), before);
      expect((await h.repository.selectMain())?.id, original.id);
      await h.db.execute('DROP TRIGGER reject_update');
      expect(await h.repository.updateItem(other.copy(mainAccount: true)), 1);
      expect((await h.repository.selectMain())?.id, other.id);
    },
  );

  test(
    'RG03-03 successful promotion leaves only the new main without changing balances',
    () async {
      final other = await h.repository.insert(h.account('Other'));
      expect(await h.repository.updateItem(other.copy(mainAccount: true)), 1);
      final accounts = await h.repository.selectAll();
      expect(
        accounts.where((account) => account.mainAccount).single.id,
        other.id,
      );
      expect(accounts.map((account) => account.total), everyElement(100));
      expect(
        accounts.singleWhere((account) => account.id == original.id).name,
        'Original',
      );
    },
  );

  test(
    'RG03-05 concurrent promotions are serialized and leave exactly one main',
    () async {
      final added = await Future.wait([
        h.repository.insert(h.account('B', main: true)),
        h.repository.insert(h.account('C', main: true)),
      ]);
      final accounts = await h.repository.selectAll();
      expect(accounts, hasLength(3));
      expect(
        added.map((account) => account.id),
        contains(accounts.where((account) => account.mainAccount).single.id),
      );
      expect(accounts.map((account) => account.order).toSet(), {0, 1, 2});
    },
  );

  test(
    'a legacy negative main ID is demoted when inserting a generated-ID main',
    () async {
      await h.db.update(
        'bankAccount',
        {'id': -1},
        where: 'id = ?',
        whereArgs: [original.id],
      );
      final replacement = await h.repository.insert(
        h.account('Replacement', main: true),
      );
      final accounts = await h.repository.selectAll();
      expect(
        accounts.where((account) => account.mainAccount).single.id,
        replacement.id,
      );
      expect(
        accounts.singleWhere((account) => account.id == -1).mainAccount,
        isFalse,
      );
    },
  );

  test(
    'an ignored target update rolls back the previous main demotion',
    () async {
      final other = await h.repository.insert(h.account('Other'));
      final before = await rows();
      await h.db.execute(
        "CREATE TRIGGER ignore_target BEFORE UPDATE ON bankAccount WHEN NEW.id = ${other.id} BEGIN SELECT RAISE(IGNORE); END",
      );
      await expectLater(
        h.repository.updateItem(other.copy(mainAccount: true)),
        throwsStateError,
      );
      expect(await rows(), before);
    },
  );

  test(
    'an ignored insert cannot return a stale last inserted ID or demote the main',
    () async {
      final before = await rows();
      await h.db.execute(
        "CREATE TRIGGER ignore_insert BEFORE INSERT ON bankAccount BEGIN SELECT RAISE(IGNORE); END",
      );
      await expectLater(
        h.repository.insert(h.account('Ignored', main: true)),
        throwsStateError,
      );
      expect(await rows(), before);
    },
  );

  test('an ignored old-main demotion aborts the whole promotion', () async {
    final other = await h.repository.insert(h.account('Other'));
    final before = await rows();
    await h.db.execute(
      "CREATE TRIGGER ignore_demotion BEFORE UPDATE ON bankAccount WHEN NEW.id = ${original.id} BEGIN SELECT RAISE(IGNORE); END",
    );
    await expectLater(
      h.repository.updateItem(other.copy(mainAccount: true)),
      throwsStateError,
    );
    expect(await rows(), before);
  });

  test(
    'updating a missing account must not demote the existing main',
    () async {
      final before = await rows();
      expect(
        await h.repository.updateItem(
          h.account('Missing', main: true).copy(id: 999),
        ),
        0,
      );
      expect(await rows(), before);
    },
  );
}
