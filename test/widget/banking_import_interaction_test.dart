import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/pages/banking/banking_navigation.dart';
import 'package:sossoldi/pages/banking/import_accounts_page.dart';
import 'package:sossoldi/pages/banking/widgets/account_import_tile.dart';
import 'package:sossoldi/pages/banking/widgets/bank_sync_context_dialog.dart';
import 'package:sossoldi/pages/banking/widgets/connection_card.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/services/banking/banking_account_import_result.dart';
import 'package:sossoldi/services/banking/banking_exception.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_callback.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_coordinator.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/ui/theme/app_theme.dart';
import '../helpers/banking_recovery_harness.dart';
import '../support/banking_recovery_actions_contract.dart'
    show pumpRecoveryUntil;

Future<void> until(WidgetTester tester, bool Function() ready) =>
    pumpRecoveryUntil(tester, ready);

class _ImportRefreshBarrier extends PendingBankAuthorizationStore
    implements BankAuthorizationScope {
  final base = const SecurePendingBankAuthorizationStore();
  bool holdNextRead = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Object get authorizationScope => base.authorizationScope;
  @override
  Future<PendingBankAuthorization?> read() async {
    final hold = holdNextRead;
    holdNextRead = false;
    final value = await base.read();
    if (hold) {
      entered.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<void> save(PendingBankAuthorization value) => base.save(value);
  @override
  Future<void> clear() => base.clear();
}

void main() {
  testWidgets(
    'failed balance preview remains selectable with visible targeted retry and no invented zero',
    (tester) async {
      final h = BankingRecoveryHarness();
      await tester.runAsync(() async {
        await h.initialize(bootstrap: false);
        await h.configure('A');
        await h.stage();
        h.balanceFailures['uid'] = const BankingException(
          providerId: 'enable_banking',
          failure: BankingFailure.unavailable,
        );
        await h.container.read(connectBankFlowProvider.notifier).resumeImport();
      });
      addTearDown(() => tester.runAsync(h.dispose));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: const MaterialApp(home: ImportAccountsPage()),
        ),
      );
      expect(find.byType(AccountImportTile), findsOneWidget);
      expect(
        find.text('The account balance could not be loaded. Try again.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'IMPORT SELECTED'),
            )
            .onPressed,
        isNotNull,
      );
      expect(h.balanceCalls, ['uid']);
      await tester.pump();
      expect(h.balanceCalls, ['uid']);
      h.balanceFailures.clear();
      h.accountCalls.clear();
      await tester.ensureVisible(find.text('Try again').last);
      await tester.tap(find.text('Try again').last);
      await until(
        tester,
        () =>
            h.container.read(connectBankFlowProvider).importStatus ==
            BankingImportStatus.ready,
      );
      expect(h.accountCalls, ['uid']);
      expect(h.balanceCalls, ['uid', 'uid']);
      expect(
        find.text('The account balance could not be loaded. Try again.'),
        findsNothing,
      );
    },
  );
  testWidgets('terminal reconnect discovery failure is visible and handled', (
    tester,
  ) async {
    final h = BankingRecoveryHarness();
    await tester.runAsync(() async {
      await h.initialize(bootstrap: false);
      await h.configure('A');
      await h.stage();
      h.accountFailures['uid'] = const BankingException(
        providerId: 'enable_banking',
        failure: BankingFailure.connectionClosed,
      );
      await h.container.read(connectBankFlowProvider.notifier).resumeImport();
      h.discoveryOffline = true;
    });
    addTearDown(() => tester.runAsync(h.dispose));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: const MaterialApp(home: ImportAccountsPage()),
      ),
    );
    await tester.tap(find.text('RECONNECT'));
    await until(
      tester,
      () => find
          .text('The bank is temporarily unavailable. Try again.')
          .evaluate()
          .isNotEmpty,
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
  });
  testWidgets(
    'real staged callback opens one PSU dialog and Cancel keeps the import reachable',
    (tester) async {
      final h = BankingRecoveryHarness();
      await tester.runAsync(() async {
        await h.initialize(bootstrap: false);
        await h.configure('A');
        await h.stage();
        h.requiredHeaders = ['Psu-Ip-Address'];
      });
      addTearDown(() => tester.runAsync(h.dispose));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: BankingNavigation(
            child: MaterialApp(
              navigatorKey: bankingNavigatorKey,
              navigatorObservers: [bankingNavigationObserver],
              home: const Scaffold(body: Text('Home')),
              routes: {
                '/connect-bank': (_) =>
                    const Scaffold(body: Text('Connections')),
                '/import-accounts': (_) => const ImportAccountsPage(),
              },
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => h.container
            .read(bankCallbackResultProvider.notifier)
            .handle(
              const BankAuthorizationCallback(
                code: 'synthetic',
                state: 'state-auth',
              ),
            ),
      );
      await until(
        tester,
        () => find.byType(BankSyncContextDialog).evaluate().isNotEmpty,
      );
      await tester.runAsync(
        () => h.container
            .read(bankCallbackResultProvider.notifier)
            .handle(
              const BankAuthorizationCallback(
                code: 'synthetic',
                state: 'state-auth',
              ),
            ),
      );
      await tester.pump();
      expect(find.byType(BankSyncContextDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await until(
        tester,
        () => find
            .text(
              'Account loading was cancelled. Try again when you are ready.',
            )
            .evaluate()
            .isNotEmpty,
      );
      expect(h.accountCalls, isEmpty);
      expect(h.posts, 0);
      expect(find.text('Try again'), findsOneWidget);
    },
  );
  for (final dark in [false, true]) {
    testWidgets(
      'ordered unavailable/failed/valid rows preserve drafts on targeted retry dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final h = BankingRecoveryHarness();
        await tester.runAsync(() async {
          await h.initialize(bootstrap: false);
          await h.configure('A');
          await h.stage();
          h.remoteUids = ['bad', 'good'];
          h.remoteAccountsData = [
            {'name': 'Savings', 'currency': 'EUR'},
            {'uid': 'bad', 'name': 'Failed checking'},
            {
              'uid': 'good',
              'name': 'Good checking',
              'identification_hash': 'good-hash',
            },
          ];
          h.accountFailures['bad'] = const BankingException(
            providerId: 'enable_banking',
            failure: BankingFailure.unavailable,
          );
          await h.container
              .read(connectBankFlowProvider.notifier)
              .resumeImport();
        });
        addTearDown(() => tester.runAsync(h.dispose));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: h.container,
            child: MaterialApp(
              theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const ImportAccountsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Savings'), findsOneWidget);
        expect(find.text('Not available for import'), findsOneWidget);
        expect(find.byType(AccountImportTile), findsOneWidget);
        final requests = h.accountCalls.length;
        await tester.pump();
        expect(h.accountCalls.length, requests);
        final name = find.widgetWithText(TextField, 'Account name');
        await tester.ensureVisible(name);
        await tester.enterText(name, 'My edited account');
        h.accountFailures.clear();
        h.accountCalls.clear();
        await tester.ensureVisible(find.text('Try again').last);
        await tester.tap(find.text('Try again').last);
        await until(
          tester,
          () =>
              h.container.read(connectBankFlowProvider).importStatus ==
                  BankingImportStatus.partial &&
              h.accountCalls.isNotEmpty,
        );
        expect(h.accountCalls, ['bad']);
        expect(find.byType(AccountImportTile), findsNWidgets(2));
        expect(find.text('My edited account'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final cancel in ['Cancel', 'back', 'dismiss']) {
    testWidgets(
      'CONTINUE IMPORT $cancel sends no account requests and allows fresh retry',
      (tester) async {
        final h = BankingRecoveryHarness();
        final refresh = _ImportRefreshBarrier();
        late Widget card;
        await tester.runAsync(() async {
          await h.initialize(bootstrap: false, pendingStore: refresh);
          await h.configure('A');
          final staged = await h.stage();
          h.requiredHeaders = ['Psu-Ip-Address'];
          card = ConnectionCard(connection: staged);
        });
        addTearDown(() async {
          if (!refresh.release.isCompleted) {
            refresh.release.complete();
          }
          await tester.runAsync(h.dispose);
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: h.container,
            child: MaterialApp(
              home: Scaffold(body: SingleChildScrollView(child: card)),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('CONTINUE IMPORT'));
        await until(
          tester,
          () => find.byType(BankSyncContextDialog).evaluate().isNotEmpty,
        );
        refresh.holdNextRead = true;
        if (cancel == 'Cancel') {
          await tester.tap(find.text('Cancel'));
        } else if (cancel == 'back') {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tapAt(const Offset(4, 4));
        }
        await until(
          tester,
          () =>
              h.container.read(connectBankFlowProvider).importStatus ==
                  BankingImportStatus.cancelled &&
              refresh.entered.isCompleted,
        );
        final continueImport = find.widgetWithText(
          TextButton,
          'CONTINUE IMPORT',
        );
        expect(tester.widget<TextButton>(continueImport).onPressed, isNull);
        expect(h.accountCalls, isEmpty);
        expect(h.balanceCalls, isEmpty);
        expect(h.contexts, isEmpty);
        h.requiredHeaders = ['Psu-User-Agent'];
        refresh.release.complete();
        await until(
          tester,
          () => tester.widget<TextButton>(continueImport).onPressed != null,
        );
        await tester.tap(find.text('CONTINUE IMPORT'));
        await until(
          tester,
          () => find.text('Browser or app details').evaluate().isNotEmpty,
        );
        expect(find.text('Your IP address'), findsNothing);
        await tester.enterText(
          find.byType(TextFormField),
          'Synthetic fresh client',
        );
        await tester.tap(find.text('Continue'));
        await until(
          tester,
          () =>
              h.container.read(connectBankFlowProvider).importStatus ==
              BankingImportStatus.ready,
        );
        expect(
          h.contexts,
          everyElement({'psu-user-agent': 'Synthetic fresh client'}),
        );
      },
    );
  }

  testWidgets(
    'import click Cancel preserves drafts and performs zero activation or sync',
    (tester) async {
      final h = BankingRecoveryHarness();
      await tester.runAsync(() async {
        await h.initialize(bootstrap: false);
        await h.configure('A');
        await h.stage();
        await h.container.read(connectBankFlowProvider.notifier).resumeImport();
      });
      addTearDown(() => tester.runAsync(h.dispose));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: const MaterialApp(home: ImportAccountsPage()),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Account name'),
        'Keep this name',
      );
      h.requiredHeaders = ['Psu-Ip-Address'];
      await tester.tap(find.text('IMPORT SELECTED'));
      await until(
        tester,
        () => find.byType(BankSyncContextDialog).evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(() => h.db.query(bankAccountTable)),
        isEmpty,
      );
      expect(h.syncCalls, 0);
      expect(find.text('Keep this name'), findsOneWidget);
    },
  );
}
