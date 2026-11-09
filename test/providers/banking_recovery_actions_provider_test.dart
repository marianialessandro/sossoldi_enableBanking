import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/transaction.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/services/banking/bank_institution.dart';

import '../helpers/banking_recovery_harness.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_coordinator.dart';

class _BlockedClearStore extends PendingBankAuthorizationStore
    implements BankAuthorizationScope {
  final base = const SecurePendingBankAuthorizationStore();
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Object get authorizationScope => base.authorizationScope;
  @override
  Future<PendingBankAuthorization?> read() => base.read();
  @override
  Future<void> save(PendingBankAuthorization value) => base.save(value);
  @override
  Future<void> clear() async {
    entered.complete();
    await release.future;
    await base.clear();
  }
}

class _ReviewPendingStore extends PendingBankAuthorizationStore
    implements BankAuthorizationScope {
  final base = const SecurePendingBankAuthorizationStore();
  Completer<void>? readEntered;
  Completer<void>? readGate;
  bool failClear = false;
  bool failReads = false;
  bool failReadsAfterClear = false;
  @override
  Object get authorizationScope => base.authorizationScope;
  @override
  Future<PendingBankAuthorization?> read() async {
    if (failReads) throw StateError('Synthetic pending read failure');
    final gate = readGate;
    final value = await base.read();
    if (readEntered != null && !readEntered!.isCompleted) {
      readEntered!.complete();
    }
    await gate?.future;
    return value;
  }

  @override
  Future<void> save(PendingBankAuthorization value) => base.save(value);
  @override
  Future<void> clear() async {
    if (failClear) {
      failReads = failReadsAfterClear;
      throw StateError('Synthetic pending cleanup failure');
    }
    await base.clear();
  }
}

void main() {
  late BankingRecoveryHarness h;
  setUp(() async {
    h = BankingRecoveryHarness();
    await h.initialize(bootstrap: false);
  });
  tearDown(() => h.dispose());

  test(
    'RECOVERY provider ownership late start error has no UI authority while cancel clear is blocked',
    () async {
      await h.dispose();
      h = BankingRecoveryHarness();
      final pending = _BlockedClearStore();
      await h.initialize(bootstrap: false, pendingStore: pending);
      await h.configure('A');
      final launchEntered = Completer<void>();
      final launchRelease = Completer<void>();
      final flow = h.container.read(connectBankFlowProvider.notifier);
      final credentials = h.store.credentialRevision;
      final first = flow.startConnection(
        BankInstitution(
          providerId: 'enable_banking',
          id: 'bank',
          name: 'Test Bank',
          country: 'IT',
          customerTypes: {BankingCustomerType.personal},
        ),
        launcher: (_) async {
          launchEntered.complete();
          await launchRelease.future;
          return true;
        },
      );
      final rejected = expectLater(first, throwsA(anything));
      final operation = flow.authorizationOperation;
      await launchEntered.future;
      final owner = h.container
          .read(connectBankFlowProvider)
          .authorizationOwner!;
      final cancel = flow.cancelAuthorization(owner);
      await pending.entered.future;
      launchRelease.complete();
      try {
        await rejected;
        expect(
          flow.isAuthorizationOperationCurrent(operation, credentials),
          isFalse,
        );
      } finally {
        pending.release.complete();
        expect((await cancel).applied, isTrue);
      }
      expect(
        flow.isAuthorizationOperationCurrent(operation, credentials),
        isFalse,
      );
    },
  );

  test(
    'RECOVERY provider ownership cancel before POST completes never launches',
    () async {
      await h.configure('A');
      h.authEntered = Completer<void>();
      h.authGate = Completer<void>();
      final flow = h.container.read(connectBankFlowProvider.notifier);
      var launches = 0;
      final start = flow.startConnection(
        BankInstitution(
          providerId: 'enable_banking',
          id: 'IT:Test Bank',
          name: 'Test Bank',
          country: 'IT',
          customerTypes: {BankingCustomerType.personal},
        ),
        launcher: (_) async {
          launches++;
          return true;
        },
      );
      final completed = expectLater(start, throwsA(anything));
      await h.authEntered!.future;
      final owner = h.container
          .read(connectBankFlowProvider)
          .authorizationOwner!;
      expect(h.container.read(connectBankFlowProvider).authorizing, isTrue);
      expect((await flow.cancelAuthorization(owner)).applied, isTrue);
      h.authGate!.complete();
      await completed;
      expect(launches, 0);
      expect(await h.pending.read(), isNull);
      expect(
        h.container.read(connectBankFlowProvider).authorizationOwner,
        isNull,
      );
    },
  );

  test(
    'RECOVERY provider ownership pending hydration works without credentials',
    () async {
      await h.stage();
      final flow = h.container.read(connectBankFlowProvider.notifier);
      await flow.refreshAuthorization();
      expect(
        h.container.read(connectBankFlowProvider).authorizationOwner,
        isNotNull,
      );
      expect(
        h.container.read(connectBankFlowProvider).authorizationOwner!.bankName,
        'Test Bank',
      );
      final owner = await flow.captureAuthorizationOwner();
      expect((await flow.cancelAuthorization(owner)).applied, isTrue);
    },
  );

  test(
    'RECOVERY provider ownership Cancel A leaves independent import B running',
    () async {
      await h.configure('A');
      await h.stage(remoteId: 'session-A', authorizationId: 'auth-A');
      final pendingA = (await h.pending.read())!;
      final b = await h.stage(remoteId: 'session-B', authorizationId: 'auth-B');
      await h.pending.save(pendingA);
      final flow = h.container.read(connectBankFlowProvider.notifier);
      final owner = (await flow.captureAuthorizationOwner())!;
      h.accountEntered = Completer<void>();
      h.accountGate = Completer<void>();
      final importing = flow.resumeImport(connectionId: b.id);
      await h.accountEntered!.future;
      expect((await flow.cancelAuthorization(owner)).applied, isTrue);
      h.accountGate!.complete();
      await importing;
      final state = h.container.read(connectBankFlowProvider);
      expect(state.connection!.sameLifecycle(b), isTrue);
      expect(state.importable, hasLength(1));
      expect(state.loading, isFalse);
      expect(await h.pending.read(), isNull);
      expect((await h.repository.selectById(b.id!)).sameLifecycle(b), isTrue);
      expect(h.deletes, 0);
    },
  );

  test(
    'RECOVERY provider ownership stale snapshot never reports local success',
    () async {
      final a = await h.stage();
      final b = a.copy(
        pendingRemoteConnectionId: 'new-session',
        pendingAuthorizationId: 'new-auth',
      );
      await h.db.update(
        'bankConnection',
        b.toJson(),
        where: 'id = ?',
        whereArgs: [a.id],
      );
      final result = await h.container
          .read(connectBankFlowProvider.notifier)
          .disconnectLocally(a);
      expect(result.status, BankRecoveryActionStatus.stale);
      expect((await h.repository.selectById(a.id!)).sameLifecycle(b), isTrue);
      expect(h.deletes, 0);
    },
  );

  for (final code in [204, 404, 401, 503]) {
    test(
      'RECOVERY provider matrix remote $code has explicit actual outcome',
      () async {
        await h.configure('A');
        final a = await h.stage();
        h.deleteStatus = code;
        final result = await h.container
            .read(connectBankFlowProvider.notifier)
            .disconnect(a);
        expect(result.applied, code == 204 || code == 404);
        final stored = await h.repository.selectById(a.id!);
        expect(
          stored.status,
          code == 204 || code == 404
              ? BankConnectionStatus.revoked
              : BankConnectionStatus.revocationPending,
        );
        expect(h.deletes, 1);
        if (code != 204 && code != 404) {
          expect(result.message, contains('Could not confirm'));
        }
      },
    );
  }

  for (final credentials in [null, 'B']) {
    test(
      'RECOVERY provider matrix local without original credentials $credentials never DELETE',
      () async {
        if (credentials != null) await h.configure(credentials);
        final a = await h.stage();
        final flow = h.container.read(connectBankFlowProvider.notifier);
        expect((await flow.disconnect(a)).applied, isFalse);
        expect(h.deletes, 0);
        final result = await flow.disconnectLocally(a);
        expect(result.applied, isTrue);
        expect(result.message, contains('Remote consent was not revoked'));
        expect(
          (await h.repository.selectById(a.id!)).status,
          BankConnectionStatus.disconnected,
        );
        expect(h.deletes, 0);
      },
    );
  }
  Future<void> history(BankConnection owner) async {
    final account = BankAccount(
      name: 'Imported',
      symbol: 'account_balance',
      color: 0,
      startingValue: 123,
      active: true,
      countNetWorth: true,
      mainAccount: true,
      order: 0,
      ebConnectionId: owner.id,
      ebAccountUid: 'uid',
    );
    final id = await h.db.insert(
      'bankAccount',
      account.toJson()..addAll({
        'createdAt': h.now.toIso8601String(),
        'updatedAt': h.now.toIso8601String(),
      }),
    );
    await h.db.insert(
      'transaction',
      Transaction(
        date: h.now,
        amount: 7,
        type: TransactionType.expense,
        idBankAccount: id,
        recurring: false,
        note: 'Personal retained note',
      ).toJson()..addAll({
        'createdAt': h.now.toIso8601String(),
        'updatedAt': h.now.toIso8601String(),
      }),
    );
    await h.db.insert('bankSyncAudit', {
      'accountId': 99,
      'status': 'partial',
      'rejected': 1,
      'warnings': '["unrelated"]',
    });
  }

  test(
    'RECOVERY provider matrix local preserves manual history notes unrelated audit journal and pending',
    () async {
      final a = await h.stage();
      await history(a);
      await h.obligation(unknown: true);
      final transaction = await h.db.query('transaction');
      final audit = await h.db.query('bankSyncAudit');
      final pending = (await h.pending.read())!;
      await h.pending.save(
        PendingBankAuthorization.fromJson({
          ...pending.toJson(),
          'state': 'independent',
          'authorization_id': 'independent',
          'staged_connection_id': null,
        }),
      );
      final issue = h.container.read(bankRecoveryIssueProvider.notifier);
      issue.reportCallbackRecovery('callback retained');
      issue.reportImportRecovery(a);
      issue.reportRecovery('journal retained');
      final result = await h.container
          .read(connectBankFlowProvider.notifier)
          .disconnectLocally(a);
      expect(result.applied, isTrue);
      expect(await h.db.query('transaction'), transaction);
      expect(await h.db.query('bankSyncAudit'), audit);
      expect((await h.db.query('bankAccount')).single['ebSessionId'], isNull);
      expect(
        (await h.db.query(
          'bankAccount',
        )).single[BankAccountFields.ebConnectionId],
        isNull,
      );
      expect((await h.pending.read())!.state, 'independent');
      expect(await h.journal.read(), hasLength(1));
      final warnings = h.container.read(bankRecoveryIssueProvider)!;
      expect(warnings, contains('callback retained'));
      expect(warnings, contains('journal retained'));
      expect(warnings, contains('account import'));
      expect(h.deletes, 0);
    },
  );

  for (final local in [true, false]) {
    test(
      'RECOVERY provider matrix SQL finalization failure local=$local is never success',
      () async {
        await h.configure('A');
        final a = await h.stage();
        await history(a);
        final before = await h.db.query('transaction');
        final status = local ? 'DISCONNECTED' : 'REVOKED';
        await h.db.execute(
          "CREATE TRIGGER recovery_fail BEFORE UPDATE ON bankConnection WHEN NEW.status = '$status' BEGIN SELECT RAISE(ABORT, 'synthetic finalization failure'); END",
        );
        final flow = h.container.read(connectBankFlowProvider.notifier);
        final result = local
            ? await flow.disconnectLocally(a)
            : await flow.disconnect(a);
        expect(result.status, BankRecoveryActionStatus.failed);
        expect(
          h.container.read(connectBankFlowProvider).recoveryNotice,
          isNull,
        );
        expect(await h.db.query('transaction'), before);
        expect(
          (await h.db.query(
            'bankAccount',
          )).single[BankAccountFields.ebConnectionId],
          a.id,
        );
        expect(
          (await h.repository.selectById(a.id!)).status,
          local ? a.status : BankConnectionStatus.revocationPending,
        );
        expect(h.deletes, local ? 0 : 1);
        await h.db.execute('DROP TRIGGER recovery_fail');
        final current = await h.repository.selectById(a.id!);
        expect(
          (local
                  ? await flow.disconnectLocally(current)
                  : await flow.disconnect(current))
              .applied,
          isTrue,
        );
      },
    );
  }

  test(
    'RECOVERY provider matrix old DELETE completion cannot replace B local result',
    () async {
      await h.configure('A');
      final a = await h.stage();
      h.deleteEntered = Completer<void>();
      h.deleteGate = Completer<void>();
      final flow = h.container.read(connectBankFlowProvider.notifier);
      final first = flow.disconnect(a);
      await h.deleteEntered!.future;
      final b = a.copy(
        pendingAuthorizationId: 'B-auth',
        pendingRemoteConnectionId: 'B-session',
      );
      await h.db.update(
        'bankConnection',
        b.toJson(),
        where: 'id = ?',
        whereArgs: [a.id],
      );
      expect((await flow.disconnectLocally(b)).applied, isTrue);
      final notice = h.container.read(connectBankFlowProvider).recoveryNotice;
      h.deleteGate!.complete();
      expect((await first).status, BankRecoveryActionStatus.stale);
      expect(
        identical(
          h.container.read(connectBankFlowProvider).recoveryNotice,
          notice,
        ),
        isTrue,
      );
      expect(
        (await h.repository.selectById(a.id!)).status,
        BankConnectionStatus.disconnected,
      );
      expect(h.deletePaths, ['/sessions/session']);
    },
  );

  test(
    'RECOVERY provider matrix institution account error 404 is not missing consent',
    () async {
      await h.configure('A');
      final a = await h.stage();
      h.deleteStatus = 404;
      h.deleteBody = '{"error":"ASPSP_ERROR","message":"Account unavailable"}';
      final result = await h.container
          .read(connectBankFlowProvider.notifier)
          .disconnect(a);
      expect(result.status, BankRecoveryActionStatus.failed);
      expect(
        (await h.repository.selectById(a.id!)).status,
        BankConnectionStatus.revocationPending,
      );
    },
  );
  Future<_ReviewPendingStore> reviewStore() async {
    await h.dispose();
    h = BankingRecoveryHarness();
    final store = _ReviewPendingStore();
    await h.initialize(bootstrap: false, pendingStore: store);
    return store;
  }

  test(
    'REVIEW CR02 activation consumes projected pending without leaving hub',
    () async {
      await h.configure('A');
      final a = await h.stage();
      final flow = h.container.read(connectBankFlowProvider.notifier);
      await flow.refreshAuthorization();
      await flow.resumeImport(connectionId: a.id);
      final account = h.container
          .read(connectBankFlowProvider)
          .importable
          .single;
      await flow.importAccounts([
        BankAccountImportSelection(
          expectedStaging: a,
          account: account,
          name: 'Checking',
          symbol: 'account_balance',
          color: 0,
        ),
      ]);
      expect(await h.pending.read(), isNull);
      expect(
        h.container.read(connectBankFlowProvider).authorizationOwner,
        isNull,
      );
      expect(
        (await h.repository.selectById(a.id!)).status,
        BankConnectionStatus.active,
      );
    },
  );

  test('REVIEW CR02 bootstrap expiry clears projected owner', () async {
    await h.configure('A');
    await h.stage();
    final flow = h.container.read(connectBankFlowProvider.notifier);
    await flow.refreshAuthorization();
    h.now = h.now.add(const Duration(minutes: 16));
    await h.container.read(bankingCallbackBootstrapProvider.future);
    expect(await h.pending.read(), isNull);
    expect(
      h.container.read(connectBankFlowProvider).authorizationOwner,
      isNull,
    );
  });

  for (final outcome in ['pending', 'failed', 'applied']) {
    test(
      'REVIEW CR03 independent B $outcome does not suppress local A warning',
      () async {
        final pending = await reviewStore();
        await h.configure('A');
        final a = await h.stage(
          authorizationId: 'A-auth',
          remoteId: 'A-session',
        );
        final pendingA = (await h.pending.read())!;
        final b = await h.stage(
          authorizationId: 'B-auth',
          remoteId: 'B-session',
        );
        await h.pending.save(pendingA);
        await history(a);
        final transactions = await h.db.query('transaction');
        final flow = h.container.read(connectBankFlowProvider.notifier);
        await flow.refreshAuthorization();
        pending.readEntered = Completer<void>();
        pending.readGate = Completer<void>();
        final local = flow.disconnectLocally(a);
        await pending.readEntered!.future;
        final localGate = pending.readGate!;
        pending.readGate = null;
        h.deleteEntered = Completer<void>();
        h.deleteGate = Completer<void>();
        h.deleteStatus = outcome == 'failed' ? 503 : 204;
        final remote = flow.disconnect(b);
        await h.deleteEntered!.future;
        if (outcome != 'pending') {
          h.deleteGate!.complete();
          await remote;
        }
        localGate.complete();
        expect((await local).applied, isTrue);
        try {
          expect(
            h.container
                .read(connectBankFlowProvider)
                .recoveryNotice
                ?.connection
                ?.id,
            a.id,
          );
          expect(
            h.container.read(connectBankFlowProvider).recoveryNotice?.message,
            contains('Remote consent was not revoked'),
          );
          expect(
            (await h.repository.selectById(a.id!)).status,
            BankConnectionStatus.disconnected,
          );
          expect(await h.db.query('transaction'), transactions);
        } finally {
          if (!h.deleteGate!.isCompleted) h.deleteGate!.complete();
          await remote;
        }
        expect(
          h.container
              .read(connectBankFlowProvider)
              .visibleRecoveryNotices
              .singleWhere((notice) => notice.connection?.id == a.id)
              .message,
          contains('Remote consent was not revoked'),
        );
      },
    );
  }

  for (final local in [true, false]) {
    for (final unreadable in [false, true]) {
      test(
        'REVIEW CR04 committed local=$local cleanup unreadable=$unreadable remains applied',
        () async {
          final pending = await reviewStore();
          await h.configure('A');
          final a = await h.stage();
          await history(a);
          final transactions = await h.db.query('transaction');
          final flow = h.container.read(connectBankFlowProvider.notifier);
          await flow.refreshAuthorization();
          pending.failClear = true;
          pending.failReadsAfterClear = unreadable;
          final result = local
              ? await flow.disconnectLocally(a)
              : await flow.disconnect(a);
          expect(result.applied, isTrue);
          expect(
            result.message,
            local
                ? contains('Remote consent was not revoked')
                : contains('Remote access is closed'),
          );
          expect(
            (await h.repository.selectById(a.id!)).status,
            local
                ? BankConnectionStatus.disconnected
                : BankConnectionStatus.revoked,
          );
          expect(await h.db.query('transaction'), transactions);
          expect(
            (await h.db.query(
              'bankAccount',
            )).single[BankAccountFields.ebConnectionId],
            isNull,
          );
          expect(h.deletes, local ? 0 : 1);
          expect(
            h.container.read(bankRecoveryIssueProvider),
            contains('cleanup'),
          );
          expect(
            h.container.read(connectBankFlowProvider).recoveryNotice!.applied,
            isTrue,
          );
          final cleanup = result.pendingCleanup!;
          pending.failReads = false;
          pending.failClear = false;
          final replacement = PendingBankAuthorization.fromJson({
            ...cleanup.toJson(),
            'state': 'replacement-B',
            'authorization_id': 'authorization-B',
            'aspsp_name': 'Bank B',
            'staged_connection_id': null,
            'phase': 'awaitingCallback',
          });
          await h.pending.save(replacement);
          expect(await flow.retryPendingCleanup(cleanup), isTrue);
          expect((await h.pending.read())!.toJson(), replacement.toJson());
          expect(
            h.container
                .read(connectBankFlowProvider)
                .authorizationOwner!
                .pending!
                .toJson(),
            replacement.toJson(),
          );
          expect(
            h.container.read(connectBankFlowProvider).visibleRecoveryNotices,
            contains(result),
          );
        },
      );
    }
  }
  test(
    'REVIEW CR03 local A survives later B completion and independent authorization',
    () async {
      await h.configure('A');
      final a = await h.stage(authorizationId: 'A-auth', remoteId: 'A-session');
      final b = await h.stage(authorizationId: 'B-auth', remoteId: 'B-session');
      final flow = h.container.read(connectBankFlowProvider.notifier);
      expect((await flow.disconnectLocally(a)).applied, isTrue);
      expect((await flow.disconnect(b)).applied, isTrue);
      final notices = h.container
          .read(connectBankFlowProvider)
          .visibleRecoveryNotices;
      expect(
        notices.map((notice) => notice.connection?.id),
        containsAll([a.id, b.id]),
      );
      expect(
        notices.firstWhere((notice) => notice.connection?.id == a.id).message,
        contains('Remote consent was not revoked'),
      );
      await flow.startConnection(
        BankInstitution(
          providerId: 'enable_banking',
          id: 'C',
          name: 'Bank C',
          country: 'IT',
          customerTypes: {BankingCustomerType.personal},
        ),
        launcher: (_) async => false,
      );
      expect(
        h.container.read(connectBankFlowProvider).visibleRecoveryNotices,
        containsAll(notices),
      );
      flow.dismissRecoveryNotice(
        notices.firstWhere((notice) => notice.connection?.id == b.id),
      );
      expect(
        h.container
            .read(connectBankFlowProvider)
            .visibleRecoveryNotices
            .single
            .connection
            ?.id,
        a.id,
      );
      expect(
        (await h.repository.selectById(a.id!)).status,
        BankConnectionStatus.disconnected,
      );
      expect(
        (await h.repository.selectById(b.id!)).status,
        BankConnectionStatus.revoked,
      );
    },
  );

  test(
    'REVIEW CR02 old projection read cannot erase newer attempt B',
    () async {
      final pending = await reviewStore();
      await h.configure('A');
      await h.stage();
      final flow = h.container.read(connectBankFlowProvider.notifier);
      await flow.refreshAuthorization();
      await h.container
          .read(bankConsentLifecycleServiceProvider)
          .cancelAuthorization();
      pending.readEntered = Completer<void>();
      pending.readGate = Completer<void>();
      final old = flow.refreshAuthorization();
      await pending.readEntered!.future;
      final release = pending.readGate!;
      pending.readGate = null;
      await flow.startConnection(
        BankInstitution(
          providerId: 'enable_banking',
          id: 'B',
          name: 'Bank B',
          country: 'IT',
          customerTypes: {BankingCustomerType.personal},
        ),
        launcher: (_) async => false,
      );
      final ownerB = h.container
          .read(connectBankFlowProvider)
          .authorizationOwner!;
      release.complete();
      await old;
      expect(
        h.container
            .read(connectBankFlowProvider)
            .authorizationOwner!
            .sameGeneration(ownerB),
        isTrue,
      );
      expect((await h.pending.read())!.institutionName, 'Bank B');
    },
  );

  test(
    'REVIEW CR02 terminal session clears projection and keeps warning origins',
    () async {
      await h.configure('A');
      final a = await h.stage();
      final flow = h.container.read(connectBankFlowProvider.notifier);
      await flow.refreshAuthorization();
      h.container
          .read(bankRecoveryIssueProvider.notifier)
          .reportCallbackRecovery('Unrelated callback warning');
      h.remoteStatus = 'CLOSED';
      await flow.resumeImport(connectionId: a.id);
      expect(await h.pending.read(), isNull);
      expect(
        h.container.read(connectBankFlowProvider).authorizationOwner,
        isNull,
      );
      expect(
        h.container.read(bankRecoveryIssueProvider),
        contains('Unrelated callback warning'),
      );
    },
  );
}
