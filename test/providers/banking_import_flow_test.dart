import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/services/banking/banking_exception.dart';
import 'package:sossoldi/services/banking/banking_account_import_result.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_request.dart';
import '../helpers/banking_recovery_harness.dart';

void main() {
  late BankingRecoveryHarness h;
  setUp(() async {
    h = BankingRecoveryHarness();
    await h.initialize();
    await h.configure('A');
    await h.stage();
  });
  tearDown(() => h.dispose());
  for (final remote in ['INVALID', 'CANCELLED', 'AUTHENTICATION']) {
    test(
      'session $remote preserves ambiguous reauth recovery without inventing application scope',
      () async {
        if (remote == 'AUTHENTICATION') {
          h.sessionFailures['/sessions/session'] = 401;
        } else {
          h.remoteStatus = remote;
        }
        await h.container.read(connectBankFlowProvider.notifier).resumeImport();
        final state = h.container.read(connectBankFlowProvider);
        expect(state.importStatus, BankingImportStatus.terminal);
        expect(state.loading, isFalse);
        expect(
          state.failureScope,
          remote == 'AUTHENTICATION'
              ? BankingImportFailureScope.application
              : BankingImportFailureScope.consent,
        );
        expect(state.canImport, isFalse);
      },
    );
  }
  for (final status in ['CLOSED', 'EXPIRED', 'REVOKED']) {
    test(
      'remote $status leaves loading with terminal recovery after lifecycle discards staging',
      () async {
        final flow = h.container.read(connectBankFlowProvider.notifier);
        await flow.resumeImport();
        expect(
          h.container.read(connectBankFlowProvider).importStatus,
          BankingImportStatus.ready,
        );
        h.remoteStatus = status;
        await flow.resumeImport();
        final state = h.container.read(connectBankFlowProvider);
        expect(state.loading, isFalse);
        expect(state.importStatus, BankingImportStatus.terminal);
        expect(state.failureScope, BankingImportFailureScope.consent);
        expect(state.canImport, isFalse);
      },
    );
  }
  for (final failingFirst in [true, false]) {
    test(
      'targeted B import skips offline A with insertion order failingFirst=$failingFirst',
      () async {
        final first = (await h.repository.selectAwaitingImport()).single;
        final second = await h.stage(
          remoteId: 'second-session',
          authorizationId: 'second-auth',
        );
        final failed = failingFirst ? first : second;
        final good = failingFirst ? second : first;
        h.sessionFailures['/sessions/${failed.pendingRemoteConnectionId}'] =
            503;
        await h.container
            .read(connectBankFlowProvider.notifier)
            .resumeImport(connectionId: good.id);
        expect(
          h.container.read(connectBankFlowProvider).importStatus,
          BankingImportStatus.ready,
        );
        expect(
          h.container.read(connectBankFlowProvider).connection!.id,
          good.id,
        );
        expect(h.sessionCalls, ['/sessions/${good.pendingRemoteConnectionId}']);
        expect(
          (await h.repository.selectById(failed.id!)).sameLifecycle(failed),
          isTrue,
        );
      },
    );
  }
  test('empty, unavailable and failed snapshots remain distinct', () async {
    final flow = h.container.read(connectBankFlowProvider.notifier);
    h.remoteUids = [];
    await flow.resumeImport();
    expect(
      h.container.read(connectBankFlowProvider).importStatus,
      BankingImportStatus.empty,
    );
    h.remoteAccountsData = [
      {
        'name': 'Savings',
        'currency': 'EUR',
        'identification_hash': 'unavailable',
      },
    ];
    await flow.resumeImport();
    expect(
      h.container.read(connectBankFlowProvider).importStatus,
      BankingImportStatus.unavailable,
    );
    expect(
      h.container.read(connectBankFlowProvider).outcomes.single.descriptor.name,
      'Savings',
    );
    expect(h.accountCalls, isEmpty);
    h.remoteUids = ['uid'];
    h.remoteAccountsData = null;
    h.accountFailures['uid'] = const BankingException(
      providerId: 'enable_banking',
      failure: BankingFailure.unavailable,
    );
    await flow.resumeImport();
    expect(
      h.container.read(connectBankFlowProvider).importStatus,
      BankingImportStatus.allFailed,
    );
    expect(h.container.read(connectBankFlowProvider).connection, isNotNull);
  });
  for (final failure in [
    BankingFailure.connectionExpired,
    BankingFailure.connectionClosed,
    BankingFailure.connectionRevoked,
    BankingFailure.authentication,
    BankingFailure.forbidden,
  ]) {
    test(
      'confirmed terminal $failure overrides earlier account success without losing metadata',
      () async {
        h.remoteUids = ['good', 'terminal', 'unread'];
        h.accountFailures['terminal'] = BankingException(
          providerId: 'enable_banking',
          failure: failure,
        );
        await h.container.read(connectBankFlowProvider.notifier).resumeImport();
        final state = h.container.read(connectBankFlowProvider);
        expect(state.importStatus, BankingImportStatus.terminal);
        expect(state.importable, isEmpty);
        expect(state.outcomes, hasLength(3));
        expect(state.outcomes.first.account, isNotNull);
        expect(h.accountCalls, ['good', 'terminal']);
      },
    );
  }
  test('account balance failure retains selectable details', () async {
    h.balanceFailures['uid'] = const BankingException(
      providerId: 'enable_banking',
      failure: BankingFailure.notFound,
    );
    await h.container.read(connectBankFlowProvider.notifier).resumeImport();
    final state = h.container.read(connectBankFlowProvider);
    expect(state.importable, hasLength(1));
    expect(state.outcomes.single.code, 'balance_unavailable');
    expect(state.outcomes.single.balance, isNull);
  });
  for (final values in <Map<String, String>>[
    {},
    {'Psu-Ip-Address': '192.0.2.1\r\nSecret: value'},
    {'Psu-Ip-Address': '192.0.2.1', 'Psu-Extra': 'invented'},
  ]) {
    test(
      'invalid PSU set never reaches account requests: ${values.keys}',
      () async {
        h.requiredHeaders = ['Psu-Ip-Address'];
        await h.container
            .read(connectBankFlowProvider.notifier)
            .resumeImport(collectContext: (_) async => values);
        expect(h.accountCalls, isEmpty);
        expect(h.balanceCalls, isEmpty);
        expect(
          h.container.read(connectBankFlowProvider).importStatus,
          BankingImportStatus.allFailed,
        );
      },
    );
  }
  test(
    'retry discovers changed requirements and storage contains no PSU values',
    () async {
      h.requiredHeaders = ['Psu-Ip-Address'];
      final flow = h.container.read(connectBankFlowProvider.notifier);
      await flow.resumeImport(
        collectContext: (_) async => {'Psu-Ip-Address': '192.0.2.1'},
      );
      h.requiredHeaders = ['Psu-User-Agent'];
      h.contexts.clear();
      await flow.resumeImport(
        collectContext: (headers) async {
          expect(headers, ['Psu-User-Agent']);
          return {'Psu-User-Agent': 'Ephemeral synthetic client'};
        },
      );
      expect(
        h.contexts,
        everyElement({'psu-user-agent': 'Ephemeral synthetic client'}),
      );
      final snapshot =
          '${await h.db.query('bankConnection')}${await h.pending.read()}${await h.journal.read()}';
      expect(snapshot, isNot(contains('192.0.2.1')));
      expect(snapshot, isNot(contains('Ephemeral synthetic client')));
      expect(
        '${h.container.read(connectBankFlowProvider)}',
        isNot(contains('Ephemeral synthetic client')),
      );
    },
  );
  test(
    'journal import and sync warnings clear only their own origin',
    () async {
      final issue = h.container.read(bankRecoveryIssueProvider.notifier);
      final staged = (await h.repository.selectAwaitingImport()).single;
      issue.reportRecovery('Journal requires attention');
      issue.reportImportRecovery(staged);
      issue.reportMessage('Sync requires attention');
      expect(
        h.container.read(bankRecoveryIssueProvider),
        contains('Journal requires attention'),
      );
      expect(
        h.container.read(bankRecoveryIssueProvider),
        contains('Other connected banks'),
      );
      expect(
        h.container.read(bankRecoveryIssueProvider),
        contains('Sync requires attention'),
      );
      issue.clear();
      expect(
        h.container.read(bankRecoveryIssueProvider),
        isNot(contains('Sync requires attention')),
      );
      issue.reportRecovery(null);
      expect(
        h.container.read(bankRecoveryIssueProvider),
        contains('Other connected banks'),
      );
      issue.reportRecovery('Journal remains');
      issue.clearImportRecovery(staged);
      expect(h.container.read(bankRecoveryIssueProvider), 'Journal remains');
      issue.reportImportRecovery(staged);
      issue.clearImportRecovery(staged.copy(pendingRemoteConnectionId: 'B'));
      expect(
        h.container.read(bankRecoveryIssueProvider),
        contains('Other connected banks'),
      );
    },
  );
  test(
    'successful independent import B cannot clear failed import A',
    () async {
      final first = (await h.repository.selectAwaitingImport()).single;
      final second = await h.stage(
        remoteId: 'session-B',
        authorizationId: 'auth-B',
      );
      expect(second.id, isNot(first.id));
      final issue = h.container.read(bankRecoveryIssueProvider.notifier);
      issue.reportImportRecovery(first);
      issue.reportImportRecovery(second);
      await h.container
          .read(connectBankFlowProvider.notifier)
          .resumeImport(connectionId: second.id);
      expect(
        h.container.read(connectBankFlowProvider).connection!.id,
        second.id,
      );
      expect(
        h.container.read(bankRecoveryIssueProvider),
        contains('Other connected banks'),
      );
      issue.clearImportRecovery(first);
      expect(h.container.read(bankRecoveryIssueProvider), isNull);
    },
  );
  for (final firstFails in [true, false]) {
    test(
      'ordered account failure is isolated first=$firstFails and retry is targeted',
      () async {
        h.remoteUids = ['one', 'two'];
        final bad = firstFails ? 'one' : 'two';
        h.accountFailures[bad] = BankingException(
          providerId: 'enable_banking',
          failure: firstFails
              ? BankingFailure.notFound
              : BankingFailure.unavailable,
        );
        final flow = h.container.read(connectBankFlowProvider.notifier);
        await flow.resumeImport();
        final state = h.container.read(connectBankFlowProvider);
        expect(state.importStatus, BankingImportStatus.partial);
        expect(
          state.outcomes.map((item) => item.descriptor.reference!.remoteId),
          ['one', 'two'],
        );
        expect(
          state.importable.single.reference.remoteId,
          firstFails ? 'two' : 'one',
        );
        h.accountFailures.clear();
        h.accountCalls.clear();
        await flow.resumeImport(
          accountReference: state.outcomes
              .firstWhere((item) => item.account == null)
              .descriptor
              .reference,
        );
        expect(h.accountCalls, [bad]);
        expect(
          h.container.read(connectBankFlowProvider).importable,
          hasLength(2),
        );
      },
    );
  }
  test(
    'PSU background and Cancel perform zero account requests; import collects fresh context',
    () async {
      h.requiredHeaders = ['Psu-Ip-Address'];
      final flow = h.container.read(connectBankFlowProvider.notifier);
      await flow.resumeImport();
      expect(
        h.container.read(connectBankFlowProvider).importStatus,
        BankingImportStatus.manualContextRequired,
      );
      await flow.resumeImport(collectContext: (_) async => null);
      expect(h.accountCalls, isEmpty);
      expect(
        h.container.read(connectBankFlowProvider).importStatus,
        BankingImportStatus.cancelled,
      );
      await flow.resumeImport(
        collectContext: (_) async => {'Psu-Ip-Address': '192.0.2.1'},
      );
      expect(h.contexts, everyElement({'psu-ip-address': '192.0.2.1'}));
      final state = h.container.read(connectBankFlowProvider);
      final selection = BankAccountImportSelection(
        expectedStaging: state.connection!,
        account: state.importable.single,
        name: 'Personal',
        symbol: 'wallet',
        color: 1,
      );
      await expectLater(
        flow.importAccounts([selection], collectContext: (_) async => null),
        throwsA(isA<ConnectBankFlowException>()),
      );
      expect(await h.db.query(bankAccountTable), isEmpty);
      expect(h.syncCalls, 0);
      await flow.importAccounts([
        selection,
      ], collectContext: (_) async => {'Psu-Ip-Address': '192.0.2.2'});
      expect(h.syncRequests.single.trigger, BankSyncTrigger.manual);
      expect(h.syncRequests.single.psuHeaders, {'psu-ip-address': '192.0.2.2'});
    },
  );
}
