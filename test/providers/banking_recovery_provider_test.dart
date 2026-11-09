import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/services/banking/banking_account_import_result.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_session_recovery_store.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_callback.dart';

import '../helpers/banking_recovery_harness.dart';

void main() {
  late BankingRecoveryHarness harness;
  setUp(() async {
    harness = BankingRecoveryHarness();
    await harness.initialize();
  });
  tearDown(() => harness.dispose());

  test(
    'CR02 corrected callback staging clears only callback warning in the same foreground',
    () async {
      await harness.configure('A');
      final staged = await harness.stage();
      final pending = (await harness.pending.read())!;
      final callback = harness.container.read(
        bankCallbackResultProvider.notifier,
      );
      final issue = harness.container.read(bankRecoveryIssueProvider.notifier);
      issue.reportRecovery('Synthetic journal recovery warning');
      issue.reportImportRecovery(staged);
      await callback.handle(
        const BankAuthorizationCallback(
          code: 'synthetic',
          state: 'wrong-state',
        ),
      );
      expect(
        harness.container.read(bankRecoveryIssueProvider),
        contains('callback'),
      );
      expect(
        harness.container.read(bankCallbackResultProvider).error,
        isNotNull,
      );
      await callback.handle(
        BankAuthorizationCallback(code: 'synthetic', state: pending.state),
      );
      final state = harness.container.read(bankCallbackResultProvider);
      expect(state.processing, isFalse);
      expect(state.error, isNull);
      expect(state.connectionId, staged.id);
      expect(
        (await harness.repository.selectById(
          state.connectionId!,
        )).sameLifecycle(staged),
        isTrue,
      );
      final warning = harness.container.read(bankRecoveryIssueProvider);
      expect(warning, isNot(contains('callback')));
      expect(warning, contains('Synthetic journal recovery warning'));
      expect(warning, contains('account import'));
      expect(harness.links.starts, 0);
      expect(harness.posts, 0);
      expect(await harness.pending.read(), isNotNull);
    },
  );

  test(
    'callback bootstrap drains cleanup and starts the actual link listener',
    () async {
      await harness.configure('A');
      await harness.obligation();
      await harness.container.read(bankingCallbackBootstrapProvider.future);
      expect(harness.deletes, 1);
      expect(harness.links.starts, 1);
      expect(await harness.journal.read(), isEmpty);
    },
  );
  test(
    'wrong app and Clear preserve obligations; verified restore retries with current credentials',
    () async {
      await harness.configure('B');
      await harness.obligation();
      await harness.container.read(bankingCallbackBootstrapProvider.future);
      final issue = harness.container.read(bankRecoveryIssueProvider.notifier);
      expect(harness.deletes, 0);
      expect(
        harness.container.read(bankRecoveryIssueProvider),
        contains('original'),
      );
      issue.clear();
      expect(
        harness.container.read(bankRecoveryIssueProvider),
        contains('original'),
      );
      await harness.container
          .read(enableBankingSettingsProvider.notifier)
          .clear();
      await harness.container
          .read(connectBankFlowProvider.notifier)
          .resumeImport();
      expect(harness.deletes, 0);
      expect(await harness.journal.read(), hasLength(1));
      await harness.saveSettings('A');
      expect(harness.deletes, 1);
      expect(await harness.journal.read(), isEmpty);
      expect(harness.container.read(bankRecoveryIssueProvider), isNull);
    },
  );
  test(
    'failed verification does not drain cleanup under unverified credentials',
    () async {
      await harness.configure('B');
      await harness.obligation();
      harness.verifyFails = true;
      await harness.saveSettings('A');
      expect(
        harness.container.read(enableBankingSettingsProvider).hasError,
        isTrue,
      );
      expect(harness.deletes, 0);
      expect(await harness.journal.read(), hasLength(1));
    },
  );
  test(
    'concurrent recovery calls share one DELETE and leave unknown warning visible',
    () async {
      await harness.configure('A');
      await harness.obligation();
      harness.deleteEntered = Completer<void>();
      harness.deleteGate = Completer<void>();
      final lifecycle = harness.container.read(
        bankConsentLifecycleServiceProvider,
      );
      final first = lifecycle.recoverSessions();
      await harness.deleteEntered!.future;
      final second = lifecycle.recoverSessions();
      expect(identical(first, second), isTrue);
      harness.deleteGate!.complete();
      await Future.wait([first, second]);
      expect(harness.deletes, 1);
      await harness.obligation(unknown: true);
      await harness.container
          .read(connectBankFlowProvider.notifier)
          .resumeImport();
      harness.container.read(bankRecoveryIssueProvider.notifier).clear();
      expect(
        harness.container.read(bankRecoveryIssueProvider),
        contains('unknown'),
      );
      expect(
        (await harness.journal.read()).single.phase,
        BankSessionRecoveryPhase.outcomeUnknown,
      );
      expect(harness.posts, 0);
    },
  );
  test(
    'real provider resumes repeated pending then ACTIVE with same import and zero POST',
    () async {
      await harness.configure('A');
      final staged = await harness.stage();
      final flow = harness.container.read(connectBankFlowProvider.notifier);
      harness.remoteStatus = 'PENDING_AUTHORIZATION';
      await flow.resumeImport();
      await flow.resumeImport();
      expect(
        harness.container.read(connectBankFlowProvider).connectionId,
        staged.id,
      );
      expect(
        harness.container.read(connectBankFlowProvider).importStatus,
        BankingImportStatus.pending,
      );
      expect(
        harness.container.read(connectBankFlowProvider).canImport,
        isFalse,
      );
      expect(harness.accountCalls, isEmpty);
      expect(
        (await harness.repository.selectById(staged.id!)).sameLifecycle(staged),
        isTrue,
      );
      harness.remoteStatus = 'AUTHORIZED';
      await flow.resumeImport();
      await flow.resumeImport();
      expect(
        harness.container
            .read(connectBankFlowProvider)
            .connection!
            .sameLifecycle(staged),
        isTrue,
      );
      expect(
        harness.container
            .read(connectBankFlowProvider)
            .importable
            .single
            .reference
            .remoteId,
        'uid',
      );
      expect(harness.posts, 0);
      expect(harness.deletes, 0);
    },
  );
}
