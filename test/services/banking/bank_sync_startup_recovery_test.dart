import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/services/banking/banking_account_import_result.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_request.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_result.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_service.dart';
import 'package:sossoldi/services/banking/storage/banking_secure_storage.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
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

class _GatedPending implements PendingBankAuthorizationStore {
  final actual = const SecurePendingBankAuthorizationStore();
  final entered = Completer<void>();
  final release = Completer<void>();
  bool gated = false;
  @override
  Future<PendingBankAuthorization?> read() async {
    if (gated) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return actual.read();
  }

  @override
  Future<void> save(PendingBankAuthorization value) => actual.save(value);
  @override
  Future<void> clear() => actual.clear();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  group('CR02 callback recovery isolation', () {
    test(
      'actual rejected callback remains visible after healthy staged import and sync',
      () async {
        sqfliteFfiInit();
        final h = BankSyncHarness(databaseFactoryFfi);
        await h.open();
        addTearDown(h.close);
        final recovery = BankingRecoveryHarness()..now = h.localTime;
        final observed = _ObservedSync(h.service);
        await recovery.initialize(syncService: observed);
        addTearDown(recovery.dispose);
        await recovery.configure('A');
        final staged = await recovery.stage();
        recovery.links.initialUri = Uri.parse(
          'sossoldi://eb-callback?code=synthetic&state=wrong-state',
        );
        final container = recovery.container;
        await container.read(enableBankingSettingsProvider.future);
        container.listen(
          bankingUiBootstrapProvider,
          (_, _) {},
          fireImmediately: true,
        );
        await observed.completed.future;
        await container.pump();
        expect(await h.transactions(), hasLength(1));
        expect(
          container.read(connectBankFlowProvider).importable,
          hasLength(1),
        );
        expect(container.read(bankCallbackResultProvider).error, isNotNull);
        final warning = container.read(bankRecoveryIssueProvider);
        expect(warning, contains('callback'));
        container.read(bankRecoveryIssueProvider.notifier).reportRecovery(null);
        container.read(bankRecoveryIssueProvider.notifier).clear();
        await container.read(connectBankFlowProvider.notifier).resumeImport();
        expect(container.read(bankRecoveryIssueProvider), warning);
        expect(
          (await recovery.repository.selectById(
            staged.id!,
          )).sameLifecycle(staged),
          isTrue,
        );
        expect(recovery.posts, 0);
      },
    );
    for (final credentials in [true, false]) {
      test(
        'corrupt pending preserved and healthy sync follows current credentials=$credentials',
        () async {
          sqfliteFfiInit();
          final h = BankSyncHarness(databaseFactoryFfi);
          await h.open();
          addTearDown(h.close);
          final recovery = BankingRecoveryHarness()..now = h.localTime;
          final observed = _ObservedSync(h.service);
          await recovery.initialize(syncService: observed);
          addTearDown(recovery.dispose);
          if (credentials) await recovery.configure('A');
          const corrupted = '{malformed synthetic pending';
          await bankingSecureStorage.write(
            key: 'eb_pending_authorization_v1',
            value: corrupted,
          );
          final container = recovery.container;
          await container.read(enableBankingSettingsProvider.future);
          container.listen(
            bankingUiBootstrapProvider,
            (_, _) {},
            fireImmediately: true,
          );
          if (credentials) {
            await observed.completed.future;
            await container.pump();
            expect(observed.calls, 1);
            expect(await h.transactions(), hasLength(1));
            expect((await h.state())['openingMinor'], '30589');
            final warning = container.read(bankRecoveryIssueProvider);
            expect(warning, contains('callback'));
            container
                .read(bankRecoveryIssueProvider.notifier)
                .reportRecovery(null);
            container.read(bankRecoveryIssueProvider.notifier).clear();
            await container
                .read(connectBankFlowProvider.notifier)
                .resumeImport();
            expect(container.read(bankRecoveryIssueProvider), warning);
            observed.completed = Completer<void>();
            binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
            binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            await observed.completed.future;
            await container.pump();
            expect(observed.calls, 2);
            expect(
              container.read(bankRecoveryIssueProvider),
              contains('callback'),
            );
          } else {
            try {
              await container.read(bankingCallbackBootstrapProvider.future);
            } catch (_) {}
            await container.pump();
            expect(observed.calls, 0);
            expect(await h.transactions(), isEmpty);
          }
          expect(
            await bankingSecureStorage.read(key: 'eb_pending_authorization_v1'),
            corrupted,
          );
          expect(recovery.posts, 0);
        },
      );
    }
    test('dispose during pending read cannot start healthy sync', () async {
      sqfliteFfiInit();
      final h = BankSyncHarness(databaseFactoryFfi);
      await h.open();
      addTearDown(h.close);
      final pending = _GatedPending();
      final recovery = BankingRecoveryHarness()..now = h.localTime;
      final observed = _ObservedSync(h.service);
      await recovery.initialize(syncService: observed, pendingStore: pending);
      await recovery.configure('A');
      pending.gated = true;
      await recovery.container.read(enableBankingSettingsProvider.future);
      recovery.container.listen(
        bankingUiBootstrapProvider,
        (_, _) {},
        fireImmediately: true,
      );
      await pending.entered.future;
      await recovery.dispose();
      pending.release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(observed.calls, 0);
      expect(await h.transactions(), isEmpty);
    });
    test(
      'credentials cleared while callback recovery waits stop independent sync',
      () async {
        sqfliteFfiInit();
        final h = BankSyncHarness(databaseFactoryFfi);
        await h.open();
        addTearDown(h.close);
        final pending = _GatedPending();
        final recovery = BankingRecoveryHarness()..now = h.localTime;
        final observed = _ObservedSync(h.service);
        await recovery.initialize(syncService: observed, pendingStore: pending);
        addTearDown(recovery.dispose);
        await recovery.configure('A');
        await recovery.container.read(enableBankingSettingsProvider.future);
        pending.gated = true;
        recovery.container.listen(
          bankingUiBootstrapProvider,
          (_, _) {},
          fireImmediately: true,
        );
        await pending.entered.future;
        await recovery.store.clear();
        pending.release.complete();
        await recovery.container.read(bankingCallbackBootstrapProvider.future);
        await recovery.container.pump();
        expect(await recovery.store.hasCredentials(), isFalse);
        expect(observed.calls, 0);
        expect(await h.transactions(), isEmpty);
      },
    );
  });
  test(
    'real offline import preserves warning while independent real sync finishes, then resume retries',
    () async {
      sqfliteFfiInit();
      final h = BankSyncHarness(databaseFactoryFfi);
      await h.open();
      addTearDown(h.close);
      final recovery = BankingRecoveryHarness()..now = h.localTime;
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
