import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/providers/accounts_provider.dart';
import 'package:sossoldi/providers/transactions_provider.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';

import '../support/main_account_test_harness.dart';

class _DelayedAccountRepository extends AccountRepository {
  _DelayedAccountRepository({required super.database});
  Completer<void>? nextReadGate;
  Completer<void>? snapshotReady;

  @override
  Future<List<BankAccount>> selectAll({bool? active, bool? deleted}) async {
    final snapshot = await super.selectAll(active: active, deleted: deleted);
    final gate = nextReadGate;
    if (gate != null) {
      nextReadGate = null;
      snapshotReady!.complete();
      await gate.future;
    }
    return snapshot;
  }
}

void main() {
  late MainAccountTestHarness h;
  late ProviderContainer container;
  late BankAccount original;
  late _DelayedAccountRepository providerRepository;

  ProviderContainer createContainer() {
    final database = MainAccountTestDatabase(h.db);
    providerRepository = _DelayedAccountRepository(database: database);
    return ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        accountRepositoryProvider.overrideWithValue(providerRepository),
      ],
    );
  }

  setUp(() async {
    h = MainAccountTestHarness();
    await h.open();
    original = await h.repository.insert(h.account('Original', main: true));
    container = createContainer();
    container.listen(selectedAccountProvider, (_, _) {});
    await container.read(accountsProvider.future);
    expect(container.read(mainAccountProvider)?.id, original.id);
  });
  tearDown(() async {
    container.dispose();
    await h.close();
  });

  Future<void> add(String name, {bool main = false}) => container
      .read(accountsProvider.notifier)
      .addAccount(name: name, icon: 'wallet', color: 1, mainAccount: main);

  test(
    'RG04-01 adding a main account refreshes an already observed main provider',
    () async {
      container.listen(mainAccountProvider, (_, _) {});
      await add('Replacement', main: true);
      final persisted = await h.repository.selectMain();
      expect(persisted?.name, 'Replacement');
      expect(container.read(mainAccountProvider)?.id, persisted?.id);
      expect(
        container
            .read(accountsProvider)
            .value!
            .where((account) => account.mainAccount)
            .single
            .id,
        persisted?.id,
      );
    },
  );

  test(
    'RG04-02 a new form uses the new main without overwriting a current manual selection',
    () async {
      container.read(selectedBankAccountProvider.notifier).setAccount(original);
      await add('Replacement', main: true);
      expect(container.read(selectedBankAccountProvider)?.id, original.id);
      container.invalidate(selectedBankAccountProvider);
      expect(container.read(selectedBankAccountProvider)?.name, 'Replacement');
    },
  );

  test(
    'RG04-03 ordinary creation and failed promotion preserve the existing main',
    () async {
      await add('Not main');
      expect(container.read(mainAccountProvider)?.id, original.id);
      await h.db.execute(
        "CREATE TRIGGER reject_insert BEFORE INSERT ON bankAccount BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      await add('Failed', main: true);
      expect(container.read(accountsProvider).hasError, isTrue);
      expect(container.read(mainAccountProvider)?.id, original.id);
      expect((await h.repository.selectMain())?.id, original.id);
      await h.db.execute('DROP TRIGGER reject_insert');
      await add('Retry', main: true);
      expect(container.read(accountsProvider).hasError, isFalse);
      expect(container.read(mainAccountProvider)?.name, 'Retry');
    },
  );

  test(
    'updating or clearing the main role refreshes the provider from persisted state',
    () async {
      final other = await h.repository.insert(h.account('Other'));
      container.read(selectedAccountProvider.notifier).setAccount(other);
      await container
          .read(accountsProvider.notifier)
          .updateAccount(mainAccount: true);
      expect(container.read(mainAccountProvider)?.id, other.id);
      final persisted = await h.repository.selectById(other.id!);
      container.read(selectedAccountProvider.notifier).setAccount(persisted);
      await container
          .read(accountsProvider.notifier)
          .updateAccount(mainAccount: false);
      expect(await h.repository.selectMain(), isNull);
      expect(container.read(mainAccountProvider), isNull);
    },
  );

  test(
    'an older delayed snapshot cannot overwrite a newer main account or accounts list',
    () async {
      final gate = Completer<void>();
      providerRepository.nextReadGate = gate;
      providerRepository.snapshotReady = Completer<void>();
      final first = add('B', main: true);
      await providerRepository.snapshotReady!.future;
      await add('C', main: true);
      expect(container.read(mainAccountProvider)?.name, 'C');
      gate.complete();
      await first;
      expect((await h.repository.selectMain())?.name, 'C');
      expect(container.read(mainAccountProvider)?.name, 'C');
      expect(
        container
            .read(accountsProvider)
            .value!
            .where((account) => account.mainAccount)
            .single
            .name,
        'C',
      );
    },
  );

  test(
    'RG04-04 live provider and a new process-style container agree after database reopen',
    () async {
      await add('Replacement', main: true);
      final liveId = container.read(mainAccountProvider)?.id;
      container.dispose();
      await h.db.close();
      await h.reopen();
      container = createContainer();
      await container.read(accountsProvider.future);
      expect(container.read(mainAccountProvider)?.id, liveId);
      expect(container.read(selectedBankAccountProvider)?.id, liveId);
    },
  );
}
