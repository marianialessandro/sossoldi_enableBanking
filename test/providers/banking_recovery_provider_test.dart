import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_session_recovery_store.dart';

import '../helpers/banking_recovery_harness.dart';

void main() {
  late BankingRecoveryHarness harness;
  setUp(() async {
    harness = BankingRecoveryHarness();
    await harness.initialize();
  });
  tearDown(() => harness.dispose());

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
        isNull,
      );
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
