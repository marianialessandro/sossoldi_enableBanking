import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';

import '../helpers/banking_recovery_harness.dart';

void main() {
  late BankingRecoveryHarness harness;
  setUp(() async {
    harness = BankingRecoveryHarness();
    await harness.initialize();
    await harness.configure('A');
  });
  tearDown(() => harness.dispose());

  BankAccountImportSelection selection(ConnectBankFlowState flow) =>
      BankAccountImportSelection(
        expectedStaging: flow.connection!,
        account: flow.importable.single,
        name: 'Imported',
        symbol: 'wallet',
        color: 1,
      );

  test(
    'real controller lifecycle SQLite imports the selected snapshot successfully',
    () async {
      final staged = await harness.stage();
      final flow = harness.container.read(connectBankFlowProvider.notifier);
      await flow.resumeImport();
      await flow.importAccounts([
        selection(harness.container.read(connectBankFlowProvider)),
      ]);
      final activated = await harness.repository.selectById(staged.id!);
      expect(activated.status, BankConnectionStatus.active);
      expect(
        (await harness.db.query(
          bankAccountTable,
        )).single[BankAccountFields.ebAccountUid],
        'uid',
      );
      expect(harness.syncCalls, 1);
    },
  );
  test(
    'A29 page snapshot A is rejected after B replaces it using the same UID and local ID',
    () async {
      final staged = await harness.stage();
      final flow = harness.container.read(connectBankFlowProvider.notifier);
      await flow.resumeImport();
      final old = selection(harness.container.read(connectBankFlowProvider));
      final replacement = staged.copy(
        pendingRemoteConnectionId: 'session-B',
        pendingAuthorizationId: 'auth-B',
      );
      await harness.db.update(
        bankConnectionTable,
        replacement.toJson(update: true, clock: harness.now),
        where: 'id = ?',
        whereArgs: [staged.id],
      );
      await flow.resumeImport();
      expect(
        harness.container
            .read(connectBankFlowProvider)
            .importable
            .single
            .reference,
        old.account.reference,
      );
      await expectLater(
        flow.importAccounts([old]),
        throwsA(isA<ConnectBankFlowException>()),
      );
      expect(await harness.db.query(bankAccountTable), isEmpty);
      expect(harness.syncCalls, 0);
      expect(
        (await harness.repository.selectById(
          staged.id!,
        )).sameLifecycle(replacement),
        isTrue,
      );
    },
  );
  for (final cancel in [false, true]) {
    test(
      'A29 snapshot survives local account await and rejects replacement cancel=$cancel',
      () async {
        final staged = await harness.stage();
        final flow = harness.container.read(connectBankFlowProvider.notifier);
        await flow.resumeImport();
        final old = selection(harness.container.read(connectBankFlowProvider));
        harness.localEntered = Completer<void>();
        harness.localGate = Completer<void>();
        final operation = flow.importAccounts([old]);
        final rejected = expectLater(operation, throwsA(anything));
        await harness.localEntered!.future;
        if (cancel) {
          await flow.cancelAuthorization();
        } else {
          final replacement = staged.copy(
            pendingRemoteConnectionId: 'session-B',
            pendingAuthorizationId: 'auth-B',
          );
          await harness.db.update(
            bankConnectionTable,
            replacement.toJson(update: true, clock: harness.now),
            where: 'id = ?',
            whereArgs: [staged.id],
          );
          await flow.resumeImport();
        }
        harness.localGate!.complete();
        await rejected;
        expect(await harness.db.query(bankAccountTable), isEmpty);
        expect(harness.syncCalls, 0);
        if (!cancel) {
          expect(
            harness.container
                .read(connectBankFlowProvider)
                .connection!
                .pendingRemoteConnectionId,
            'session-B',
          );
        }
      },
    );
  }
  test('late account read A cannot replace the completed resume B', () async {
    final staged = await harness.stage();
    final flow = harness.container.read(connectBankFlowProvider.notifier);
    harness.accountEntered = Completer<void>();
    harness.accountGate = Completer<void>();
    final first = flow.resumeImport();
    await harness.accountEntered!.future;
    final gate = harness.accountGate!;
    harness.accountGate = null;
    final replacement = staged.copy(
      pendingRemoteConnectionId: 'session-B',
      pendingAuthorizationId: 'auth-B',
    );
    await harness.db.update(
      bankConnectionTable,
      replacement.toJson(update: true, clock: harness.now),
      where: 'id = ?',
      whereArgs: [staged.id],
    );
    await flow.resumeImport();
    gate.complete();
    await first;
    expect(
      harness.container
          .read(connectBankFlowProvider)
          .connection!
          .sameLifecycle(replacement),
      isTrue,
    );
    expect(harness.posts, 0);
  });
}
