import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/services/banking/banking_account_import_result.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_request.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_result.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../support/bank_sync_harness.dart';
import '../../helpers/banking_recovery_harness.dart';

class _ObservedSync implements BankSyncService {
  final BankSyncService actual;
  Completer<void> completed = Completer<void>();
  int calls = 0;
  _ObservedSync(this.actual);
  @override
  Future<BankSyncSummary> syncAll({
    BankSyncRequest request = const BankSyncRequest(),
  }) async {
    calls++;
    try {
      return await actual.syncAll(request: request);
    } finally {
      if (!completed.isCompleted) completed.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real offline import preserves warning while independent real sync finishes, then resume retries',
    () async {
      sqfliteFfiInit();
      final h = BankSyncHarness(databaseFactoryFfi);
      await h.open();
      addTearDown(h.close);
      final recovery = BankingRecoveryHarness();
      final observed = _ObservedSync(h.service);
      await recovery.initialize(syncService: observed);
      addTearDown(recovery.dispose);
      await recovery.configure('A');
      final staged = await recovery.stage();
      recovery.sessionOffline = true;
      final container = recovery.container;
      container.listen(
        bankingUiBootstrapProvider,
        (_, _) {},
        fireImmediately: true,
      );
      await observed.completed.future;
      await container.pump();
      expect(observed.calls, 1);
      expect(await h.transactions(), hasLength(1));
      expect(
        container.read(connectBankFlowProvider).importStatus,
        BankingImportStatus.allFailed,
      );
      expect(
        container.read(bankRecoveryIssueProvider),
        contains('Other connected banks can still sync'),
      );
      expect(
        (await recovery.repository.selectById(
          staged.id!,
        )).sameLifecycle(staged),
        isTrue,
      );
      recovery.sessionOffline = false;
      observed.completed = Completer<void>();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await observed.completed.future;
      await container.pump();
      expect(observed.calls, 2);
      expect(await h.transactions(), hasLength(1));
      expect(container.read(bankRecoveryIssueProvider), isNull);
      expect(container.read(connectBankFlowProvider).importable, hasLength(1));
      expect(recovery.posts, 0);
    },
  );
}
