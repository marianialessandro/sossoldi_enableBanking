import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/pages/banking/connect_bank_page.dart';
import 'package:sossoldi/pages/banking/import_accounts_page.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_callback.dart';
import 'package:sossoldi/pages/banking/widgets/confirm_disconnect_dialog.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/ui/theme/app_theme.dart';

import '../helpers/banking_recovery_harness.dart';
import '../support/banking_recovery_actions_contract.dart';
import '../support/banking_recovery_actions_harness.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sossoldi/services/banking/bank_institution.dart';

Future<BankingRecoveryHarness> mountRecovery(WidgetTester tester) async {
  final h = BankingRecoveryHarness();
  await tester.runAsync(() async {
    await h.initialize(bootstrap: false);
    await h.stage();
    await h.container
        .read(connectBankFlowProvider.notifier)
        .refreshAuthorization();
    await h.container.read(bankConnectionsProvider.future);
  });
  addTearDown(() async {
    var refreshed = false;
    final refresh = h.container
        .read(connectBankFlowProvider.notifier)
        .refreshAuthorization()
        .whenComplete(() => refreshed = true);
    await pumpRecoveryUntil(tester, () => refreshed, settle: false);
    await refresh;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(h.dispose);
    await tester.pump(Duration.zero);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: const ConnectBankPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  var refreshed = false;
  final refresh = h.container
      .read(connectBankFlowProvider.notifier)
      .refreshAuthorization()
      .whenComplete(() => refreshed = true);
  await pumpRecoveryUntil(
    tester,
    () => refreshed && !h.container.read(bankConnectionsProvider).isLoading,
  );
  await refresh;
  return h;
}

void main() {
  testWidgets(
    'REVIEW CR02 mounted hub returns from actual import without pending controls',
    (tester) async {
      final h = BankingRecoveryHarness();
      await tester.runAsync(() async {
        await h.initialize(bootstrap: false);
        await h.configure('A');
        h.allowSessionCreation = true;
        await h.container.read(enableBankingSettingsProvider.future);
      });
      addTearDown(() => tester.runAsync(h.dispose));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            initialRoute: '/connect-bank',
            routes: {
              '/': (_) => const SizedBox.shrink(),
              '/connect-bank': (_) => const ConnectBankPage(),
            },
          ),
        ),
      );
      await pumpRecoveryUntil(
        tester,
        () => !h.container.read(bankConnectionsProvider).isLoading,
      );
      final hub = tester.state(find.byType(ConnectBankPage));
      final flow = h.container.read(connectBankFlowProvider.notifier);
      await tester.runAsync(
        () => flow.startConnection(
          BankInstitution(
            providerId: 'enable_banking',
            id: 'IT:Test Bank',
            name: 'Test Bank',
            country: 'IT',
            customerTypes: {BankingCustomerType.personal},
          ),
          launcher: (_) async => false,
        ),
      );
      final pending = (await tester.runAsync(h.pending.read))!;
      await tester.runAsync(() async {
        await h.container
            .read(bankCallbackResultProvider.notifier)
            .handle(
              BankAuthorizationCallback(
                code: 'synthetic-code',
                state: pending.state,
              ),
            );
        await flow.resumeImport(
          connectionId: h.container
              .read(bankCallbackResultProvider)
              .connectionId,
        );
      });
      expect(
        h.container.read(connectBankFlowProvider).importable,
        hasLength(1),
      );
      Navigator.of(tester.element(find.byType(ConnectBankPage))).push(
        MaterialPageRoute<void>(builder: (_) => const ImportAccountsPage()),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'IMPORT SELECTED'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.runAsync(() => tester.tap(find.text('IMPORT SELECTED')));
      await pumpRecoveryUntil(
        tester,
        () =>
            find
                .text('Could not import the accounts. Try again.')
                .evaluate()
                .isNotEmpty ||
            find.byType(ImportAccountsPage).evaluate().isEmpty ||
            find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        identical(tester.state(find.byType(ConnectBankPage)), hub),
        isTrue,
      );
      expect(await tester.runAsync(h.pending.read), isNull);
      expect(
        h.container.read(connectBankFlowProvider).authorizationOwner,
        isNull,
      );
      expect(find.text('Waiting for bank authorization'), findsNothing);
      expect(find.text('Cancel attempt'), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Link a bank',
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(h.authPosts, 1);
      expect(h.posts, 1);
      expect(
        (await tester.runAsync(() => h.repository.selectAll()))!.single.status,
        BankConnectionStatus.active,
      );
    },
  );

  testWidgets(
    'REVIEW CR03 hub renders and dismisses independent notices separately',
    (tester) async {
      final h = await mountRecovery(tester);
      late int aId;
      late int bId;
      final subscriptions = <ProviderSubscription<dynamic>>[];
      await tester.runAsync(() async {
        await h.configure('A');
        final a = (await h.repository.selectAll()).single;
        final b = await h.stage(
          authorizationId: 'B-auth',
          remoteId: 'B-session',
        );
        aId = a.id!;
        bId = b.id!;
        subscriptions.add(
          h.container.listen(bankConnectionSyncStatusProvider(aId), (_, _) {}),
        );
        subscriptions.add(
          h.container.listen(bankConnectionSyncStatusProvider(bId), (_, _) {}),
        );
        final flow = h.container.read(connectBankFlowProvider.notifier);
        expect((await flow.disconnectLocally(a)).applied, isTrue);
        expect((await flow.disconnect(b)).applied, isTrue);
      });
      await pumpRecoveryUntil(
        tester,
        () =>
            !h.container.read(bankConnectionsProvider).isLoading &&
            !h.container
                .read(bankConnectionSyncStatusProvider(aId))
                .isLoading &&
            !h.container.read(bankConnectionSyncStatusProvider(bId)).isLoading,
      );
      expect(
        find.textContaining('Remote consent was not revoked'),
        findsOneWidget,
      );
      expect(
        find.text('Bank disconnected. Remote access is closed.'),
        findsOneWidget,
      );
      expect(find.text('Dismiss'), findsNWidgets(2));
      await tester.ensureVisible(find.text('Dismiss').last);
      await tester.tap(find.text('Dismiss').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Remote consent was not revoked'),
        findsOneWidget,
      );
      expect(find.text('Dismiss'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>(() {}));
      for (final subscription in subscriptions) {
        subscription.close();
      }
      await tester.pump(Duration.zero);
    },
  );

  testWidgets(
    'RECOVERY UI cancel pending remains visible without credentials and decline is safe',
    (tester) async {
      final h = await mountRecovery(tester);
      expect(find.text('CONFIGURE'), findsOneWidget);
      expect(find.text('Test Bank'), findsWidgets);
      await tester.tap(find.text('Cancel attempt'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel connection attempt?'), findsOneWidget);
      await tester.tap(find.text('Keep attempt'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(h.pending.read), isNotNull);
      expect(h.deletes, 0);
      await tester.tap(find.text('Cancel attempt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel attempt').last);
      await pumpRecoveryUntil(
        tester,
        () =>
            h.container.read(connectBankFlowProvider).recoveryNotice?.applied ==
            true,
      );
      expect(await tester.runAsync(h.pending.read), isNull);
      expect(
        find.text('Connection attempt cancelled. You can choose another bank.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'RECOVERY UI disconnect local is distinct and notice survives last card',
    (tester) async {
      final h = await mountRecovery(tester);
      await tester.ensureVisible(find.text('Disconnect locally'));
      await tester.tap(find.text('Disconnect locally'));
      await tester.pumpAndSettle();
      expect(find.text('Disconnect locally only?'), findsOneWidget);
      expect(
        find.textContaining('This does not revoke remote consent'),
        findsOneWidget,
      );
      await tester.tap(find.text('Keep connection'));
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(() => h.repository.selectAll()),
        hasLength(1),
      );
      await tester.tap(find.text('Disconnect locally'));
      await tester.pumpAndSettle();
      final applied = Completer<void>();
      final subscription = h.container.listen(connectBankFlowProvider, (
        _,
        next,
      ) {
        if (next.recoveryActions.any(
              (r) => r.status != BankRecoveryActionStatus.running,
            ) &&
            !applied.isCompleted) {
          applied.complete();
        }
      });
      await tester.tap(find.text('Disconnect locally').last);
      while (!applied.isCompleted) {
        await tester.pump();
        await tester.runAsync(() => Future<void>(() {}));
      }
      while (h.container.read(bankConnectionsProvider).isLoading) {
        await tester.pump();
        await tester.runAsync(() => Future<void>(() {}));
      }
      subscription.close();
      await tester.pumpAndSettle();
      expect(h.deletes, 0);
      expect(
        find.textContaining('Remote consent was not revoked by this action'),
        findsOneWidget,
      );
      expect(find.text('Dismiss'), findsOneWidget);
      expect(find.text('Disconnect locally'), findsNothing);
    },
  );

  for (final code in [204, 404, 401, 503]) {
    testWidgets('RECOVERY UI disconnect remote $code persists actual outcome', (
      tester,
    ) async {
      final h = await mountRecovery(tester);
      await tester.runAsync(() async {
        await h.configure('A');
        h.container.invalidate(enableBankingSettingsProvider);
        await h.container.read(enableBankingSettingsProvider.future);
      });
      h.deleteStatus = code;
      await tester.pumpAndSettle();
      final invoker = find.byTooltip('Disconnect and revoke Test Bank');
      await tester.ensureVisible(invoker);
      await tester.tap(invoker);
      await tester.pumpAndSettle();
      expect(find.text('Disconnect and revoke consent?'), findsOneWidget);
      await tester.tap(find.text('Disconnect and revoke'));
      await pumpRecoveryUntil(
        tester,
        () =>
            h.container
                .read(connectBankFlowProvider)
                .recoveryActions
                .any((r) => r.status != BankRecoveryActionStatus.running) &&
            !h.container.read(bankConnectionsProvider).isLoading,
      );
      expect(h.deletes, 1);
      if (code == 204 || code == 404) {
        expect(
          find.text('Bank disconnected. Remote access is closed.'),
          findsOneWidget,
        );
        expect(find.text('Disconnect locally'), findsNothing);
      } else {
        expect(
          find.text(
            'Could not confirm that bank consent was revoked. Try again, or disconnect locally. Remote consent may still be active.',
          ),
          findsOneWidget,
        );
        expect(find.text('Disconnect locally'), findsOneWidget);
        expect(find.text('Try again'), findsWidgets);
      }
    });
  }

  testWidgets('RECOVERY UI cancel dialog A cannot cancel B while open', (
    tester,
  ) async {
    final h = await mountRecovery(tester);
    await tester.tap(find.text('Cancel attempt'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await h.configure('A');
      await h.container
          .read(bankConsentLifecycleServiceProvider)
          .cancelAuthorization();
      await h.container
          .read(connectBankFlowProvider.notifier)
          .startConnection(
            BankInstitution(
              providerId: 'enable_banking',
              id: 'B',
              name: 'Bank B',
              country: 'IT',
              customerTypes: {BankingCustomerType.personal},
            ),
            launcher: (_) async => false,
          );
    });
    await tester.tap(find.text('Cancel attempt').last);
    await pumpRecoveryUntil(
      tester,
      () =>
          h.container.read(connectBankFlowProvider).recoveryNotice?.status ==
          BankRecoveryActionStatus.stale,
    );
    expect((await tester.runAsync(h.pending.read))!.institutionName, 'Bank B');
    expect(find.text(bankRecoveryStaleMessage), findsOneWidget);
    expect(h.deletes, 0);
  });

  testWidgets('REVIEW CR01 pending browser failure exposes a tappable retry', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    sqfliteFfiInit();
    final h = BankingRecoveryActionsHarness(
      factory: databaseFactoryFfi,
      storage: const FlutterSecureStorage(),
    );
    try {
      await tester.runAsync(() async {
        await h.open();
        await h.configure('qa-recovery');
      });
      await h.mount(tester);
      final flow = h.container.read(connectBankFlowProvider.notifier);
      await tester.runAsync(
        () => flow.startConnection(h.institution('Bank A'), launcher: h.launch),
      );
      final before = (await tester.runAsync(h.pending.read))!;
      final owner = h.container
          .read(connectBankFlowProvider)
          .authorizationOwner!;
      await tester.pumpAndSettle();
      expect(h.launches, 1);
      expect(find.text('Try again'), findsOneWidget);
      h.browserOpens = true;
      await tester.tap(find.text('Try again'));
      await pumpRecoveryUntil(
        tester,
        () =>
            h.launches == 2 &&
            !h.container.read(connectBankFlowProvider).authorizing,
      );
      expect(h.posts, 1);
      expect(h.launchUrls, [
        Uri.parse(before.authorizationUrl),
        Uri.parse(before.authorizationUrl),
      ]);
      expect(
        (await tester.runAsync(h.pending.read))!.toJson(),
        before.toJson(),
      );
      expect(
        h.container
            .read(connectBankFlowProvider)
            .authorizationOwner!
            .sameGeneration(owner),
        isTrue,
      );
    } finally {
      await h.close(tester);
    }
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0, 3.2]) {
        for (final kind in ['cancel', 'remote', 'local']) {
          testWidgets(
            'RECOVERY UI accessibility $platform $kind dark=$dark scale=$scale safe focus and reachable actions',
            (tester) async {
              tester.view.physicalSize = const Size(320, 900);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              final semantics = tester.ensureSemantics();
              try {
                const bank =
                    'A very long readable international banking institution';
                final snapshot = const BankConnection(
                  id: 1,
                  providerId: 'synthetic',
                  institutionName: bank,
                  institutionCountry: 'IT',
                  applicationId: 'A',
                  status: BankConnectionStatus.active,
                );
                var confirmed = false;
                final boundaryKey = GlobalKey();
                await tester.pumpWidget(
                  MaterialApp(
                    theme: (dark ? AppTheme.darkTheme : AppTheme.lightTheme)
                        .copyWith(platform: platform),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: RepaintBoundary(key: boundaryKey, child: child!),
                    ),
                    home: Builder(
                      builder: (context) => Scaffold(
                        body: TextButton(
                          onPressed: () async {
                            confirmed =
                                await showDialog<bool>(
                                  context: context,
                                  builder: (_) => switch (kind) {
                                    'cancel' =>
                                      const ConfirmCancelAuthorizationDialog(
                                        bankName: bank,
                                      ),
                                    'local' => ConfirmLocalDisconnectDialog(
                                      connection: snapshot,
                                    ),
                                    _ => ConfirmDisconnectDialog(
                                      connection: snapshot,
                                    ),
                                  },
                                ) ??
                                false;
                          },
                          child: const Text('Open'),
                        ),
                      ),
                    ),
                  ),
                );
                await tester.tap(find.text('Open'));
                await tester.pumpAndSettle();
                final negative = find.text(
                  kind == 'cancel' ? 'Keep attempt' : 'Keep connection',
                );
                expect(
                  FocusManager.instance.primaryFocus?.context?.widget,
                  isNotNull,
                );
                expect(Focus.of(tester.element(negative)).hasFocus, isTrue);
                expect(
                  tester
                      .getSize(
                        find.ancestor(
                          of: negative,
                          matching: find.byType(
                            platform == TargetPlatform.android
                                ? TextButton
                                : CupertinoDialogAction,
                          ),
                        ),
                      )
                      .height,
                  greaterThanOrEqualTo(48),
                );
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.pumpAndSettle();
                expect(Focus.of(tester.element(negative)).hasFocus, isFalse);
                await tester.sendKeyEvent(LogicalKeyboardKey.tab);
                await tester.pumpAndSettle();
                expect(Focus.of(tester.element(negative)).hasFocus, isTrue);
                final evidence = Platform
                    .environment['BANKING_UI_ACCESSIBILITY_SCREENSHOTS'];
                if (evidence != null) {
                  await tester.runAsync(() async {
                    final boundary =
                        boundaryKey.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary;
                    final rendered = await boundary.toImage();
                    final bytes = await rendered.toByteData(
                      format: ui.ImageByteFormat.png,
                    );
                    await File(
                      '$evidence/recovery-${platform.name}-$kind-$dark-$scale.png',
                    ).writeAsBytes(bytes!.buffer.asUint8List());
                    rendered.dispose();
                  });
                }
                await tester.sendKeyEvent(LogicalKeyboardKey.enter);
                await tester.pumpAndSettle();
                expect(confirmed, isFalse);
                expect(find.text('Open'), findsOneWidget);
                for (final dismiss in ['escape', 'back', 'barrier', 'space']) {
                  await tester.tap(find.text('Open'));
                  await tester.pumpAndSettle();
                  switch (dismiss) {
                    case 'escape':
                      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
                    case 'back':
                      await tester.binding.handlePopRoute();
                    case 'barrier':
                      await tester.tapAt(const Offset(1, 1));
                    case 'space':
                      await tester.sendKeyEvent(LogicalKeyboardKey.space);
                  }
                  await tester.pumpAndSettle();
                  expect(confirmed, isFalse);
                  expect(find.text('Open'), findsOneWidget);
                }

                expect(tester.takeException(), isNull);
              } finally {
                semantics.dispose();
              }
            },
          );
        }
      }
    }
  }
}
