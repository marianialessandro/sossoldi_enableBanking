import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/pages/banking/widgets/aspsp_selector.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_coordinator.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_callback.dart';
import 'package:sqflite/sqflite.dart';

import 'banking_recovery_actions_harness.dart';

class _CleanupFault {
  bool fail = false;
}

class _CleanupStore extends PendingBankAuthorizationStore
    implements BankAuthorizationScope {
  final SecurePendingBankAuthorizationStore base;
  final _CleanupFault fault;
  _CleanupStore(FlutterSecureStorage storage, this.fault)
    : base = SecurePendingBankAuthorizationStore(storage: storage);
  @override
  Object get authorizationScope => base.authorizationScope;
  @override
  Future<PendingBankAuthorization?> read() => base.read();
  @override
  Future<void> save(PendingBankAuthorization pending) => base.save(pending);
  @override
  Future<void> clear() async {
    if (fault.fail) {
      throw StateError('Synthetic post-finalization clear failure');
    }
    await base.clear();
  }
}

class _CallbackPhaseStore extends PendingBankAuthorizationStore
    implements BankAuthorizationScope {
  final SecurePendingBankAuthorizationStore base;
  final bool persistBeforePause;
  final resumeReadEntered = Completer<void>();
  final resumeReadRelease = Completer<void>();
  final stagedSaveEntered = Completer<void>();
  final stagedSaveRelease = Completer<void>();
  int? pauseReadAt;
  int reads = 0;
  _CallbackPhaseStore(FlutterSecureStorage storage, this.persistBeforePause)
    : base = SecurePendingBankAuthorizationStore(storage: storage);
  @override
  Object get authorizationScope => base.authorizationScope;
  @override
  Future<PendingBankAuthorization?> read() async {
    final pause = ++reads == pauseReadAt;
    final value = await base.read();
    if (pause) {
      resumeReadEntered.complete();
      await resumeReadRelease.future;
    }
    return value;
  }

  @override
  Future<void> save(PendingBankAuthorization pending) async {
    if (pending.phase != PendingAuthorizationPhase.connectionStaged) {
      await base.save(pending);
      return;
    }
    if (persistBeforePause) await base.save(pending);
    stagedSaveEntered.complete();
    await stagedSaveRelease.future;
    if (!persistBeforePause) await base.save(pending);
  }

  @override
  Future<void> clear() => base.clear();
}

/// Pumps fake frames and real I/O events until an explicit state barrier is reached.
Future<void> pumpRecoveryUntil(
  WidgetTester tester,
  bool Function() done, {
  bool settle = true,
}) async {
  while (!done()) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(() => Future<void>(() {}));
  }
  if (settle) await tester.pumpAndSettle();
}

Map<String, Future<void> Function(WidgetTester)> recoveryActionCases({
  required DatabaseFactory factory,
  required FlutterSecureStorage storage,
}) => {
  for (final persistBeforePause in [true, false])
    'REVIEW CR05 callback phase persisted=$persistBeforePause invalidates suspended resume before launch':
        (tester) async {
          late _CallbackPhaseStore pending;
          final h = BankingRecoveryActionsHarness(
            factory: factory,
            storage: storage,
            pendingFactory: (storage) =>
                pending = _CallbackPhaseStore(storage, persistBeforePause),
          );
          Future<void>? callbackDone;
          try {
            await tester.runAsync(() async {
              await h.open();
              await h.configure('qa-recovery');
            });
            await h.mount(tester);
            final flow = h.container.read(connectBankFlowProvider.notifier);
            await tester.runAsync(
              () => flow.startConnection(
                h.institution('Bank A'),
                launcher: h.launch,
              ),
            );
            final original = (await tester.runAsync(h.pending.read))!;
            final owner = h.container
                .read(connectBankFlowProvider)
                .authorizationOwner!;
            pending.reads = 0;
            pending.pauseReadAt = 2;
            var resumeFinished = false;
            final resume = flow
                .resumeAuthorization(owner)
                .whenComplete(() => resumeFinished = true);
            await pumpRecoveryUntil(
              tester,
              () => pending.resumeReadEntered.isCompleted,
              settle: false,
            );
            var callbackFinished = false;
            callbackDone = h.container
                .read(bankCallbackResultProvider.notifier)
                .handle(
                  BankAuthorizationCallback(
                    code: 'qa-callback-code',
                    state: original.state,
                  ),
                )
                .then<void>((_) => callbackFinished = true);
            await pumpRecoveryUntil(
              tester,
              () => pending.stagedSaveEntered.isCompleted,
              settle: false,
            );
            final staged = (await tester.runAsync(
              h.repository.selectAwaitingImport,
            ))!.single;
            final published = (await tester.runAsync(h.pending.read))!;
            expect(published.state, original.state);
            expect(published.authorizationId, original.authorizationId);
            expect(published.applicationId, original.applicationId);
            expect(
              published.phase,
              persistBeforePause
                  ? PendingAuthorizationPhase.connectionStaged
                  : PendingAuthorizationPhase.awaitingCallback,
            );
            expect(
              h.container.read(bankCallbackResultProvider).connectionId,
              isNull,
            );
            expect(
              owner.pending!.phase,
              PendingAuthorizationPhase.awaitingCallback,
            );
            pending.resumeReadRelease.complete();
            await pumpRecoveryUntil(
              tester,
              () => resumeFinished,
              settle: false,
            );
            await resume;
            expect(h.launches, 1);
            expect(
              h.container
                  .read(bankConsentLifecycleServiceProvider)
                  .isAuthorizationOwnerCurrent(owner),
              isFalse,
            );
            expect(
              (await tester.runAsync(h.pending.read))!.toJson(),
              published.toJson(),
            );
            expect(
              h.container
                  .read(connectBankFlowProvider)
                  .authorizationOwner!
                  .pending!
                  .phase,
              PendingAuthorizationPhase.connectionStaged,
            );
            expect(
              h.container
                  .read(connectBankFlowProvider)
                  .visibleRecoveryNotices
                  .where(
                    (notice) =>
                        notice.kind == BankRecoveryActionKind.resume &&
                        notice.status == BankRecoveryActionStatus.failed,
                  ),
              isEmpty,
            );
            expect(
              (await tester.runAsync(
                () => h.repository.selectById(staged.id!),
              ))!.sameLifecycle(staged),
              isTrue,
            );
            pending.stagedSaveRelease.complete();
            await pumpRecoveryUntil(tester, () => callbackFinished);
            await callbackDone;
            expect(
              h.container.read(bankCallbackResultProvider).connectionId,
              staged.id,
            );
            final finalPending = (await tester.runAsync(h.pending.read))!;
            expect(finalPending.state, original.state);
            expect(finalPending.authorizationId, original.authorizationId);
            expect(finalPending.applicationId, original.applicationId);
            expect(
              finalPending.phase,
              PendingAuthorizationPhase.connectionStaged,
            );
            expect(finalPending.stagedConnectionId, staged.id);
            expect(
              finalPending.toJson(),
              original
                  .copy(
                    stagedConnectionId: staged.id,
                    phase: PendingAuthorizationPhase.connectionStaged,
                  )
                  .toJson(),
            );
            expect(h.launches, 1);
            expect(h.posts, 1);
            expect(h.sessionPosts, 1);
            expect(h.deletes, 0);
          } finally {
            if (!pending.resumeReadRelease.isCompleted) {
              pending.resumeReadRelease.complete();
            }
            if (!pending.stagedSaveRelease.isCompleted) {
              pending.stagedSaveRelease.complete();
            }
            if (callbackDone != null) {
              var finished = false;
              callbackDone.whenComplete(() => finished = true);
              await pumpRecoveryUntil(tester, () => finished, settle: false);
              await callbackDone;
            }
            await h.close(tester);
          }
        },
  'REVIEW CR01 contract resume uses stored URL and cancel blocks late navigation':
      (tester) async {
        final h = BankingRecoveryActionsHarness(
          factory: factory,
          storage: storage,
        );
        final controller = ScrollController();
        try {
          await tester.runAsync(() async {
            await h.open();
            await h.configure('qa-recovery');
          });
          await h.mount(tester);
          final flow = h.container.read(connectBankFlowProvider.notifier);
          await tester.runAsync(
            () => flow.startConnection(
              h.institution('Bank A'),
              launcher: h.launch,
            ),
          );
          final pending = (await tester.runAsync(h.pending.read))!;
          final owner = h.container
              .read(connectBankFlowProvider)
              .authorizationOwner!;
          h.browserOpens = true;
          await tester.pumpAndSettle();
          await tester.tap(find.text('Try again'));
          await pumpRecoveryUntil(
            tester,
            () =>
                h.finishedLaunches == 2 &&
                !h.container.read(connectBankFlowProvider).authorizing,
          );
          expect(h.posts, 1);
          expect(h.launchUrls, [
            Uri.parse(pending.authorizationUrl),
            Uri.parse(pending.authorizationUrl),
          ]);
          expect(
            (await tester.runAsync(h.pending.read))!.toJson(),
            pending.toJson(),
          );
          expect(
            h.container
                .read(connectBankFlowProvider)
                .authorizationOwner!
                .sameGeneration(owner),
            isTrue,
          );
          Navigator.of(tester.element(find.text('Connect bank'))).push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: AspspSelector(
                  country: 'IT',
                  scrollController: controller,
                ),
              ),
            ),
          );
          await pumpRecoveryUntil(
            tester,
            () =>
                find.byType(AspspSelector).evaluate().isNotEmpty &&
                find.byType(CircularProgressIndicator).evaluate().isEmpty,
          );
          h.launchEntered = Completer<void>();
          h.launchGate = Completer<void>();
          await tester.tap(find.text('Try again'));
          await pumpRecoveryUntil(
            tester,
            () => h.launchEntered!.isCompleted,
            settle: false,
          );
          await tester.tap(find.text('Cancel attempt'));
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          await tester.tap(find.text('Cancel attempt').last);
          await pumpRecoveryUntil(
            tester,
            () =>
                h.container.read(connectBankFlowProvider).authorizationOwner ==
                null,
            settle: false,
          );
          h.launchGate!.complete();
          await pumpRecoveryUntil(
            tester,
            () =>
                h.finishedLaunches == 3 &&
                !h.container.read(connectBankFlowProvider).authorizing,
          );
          expect(find.byType(AspspSelector), findsOneWidget);
          expect(await tester.runAsync(h.pending.read), isNull);
          expect(h.posts, 1);
        } finally {
          await h.close(tester);
          controller.dispose();
        }
      },
  for (final local in [true, false])
    'REVIEW CR04 contract finalized local=$local cleanup reopens and preserves replacement B':
        (tester) async {
          final fault = _CleanupFault();
          final h = BankingRecoveryActionsHarness(
            factory: factory,
            storage: storage,
            pendingFactory: (storage) => _CleanupStore(storage, fault),
          );
          try {
            late BankConnection staged;
            late List<Map<String, Object?>> history;
            await tester.runAsync(() async {
              await h.open();
              await h.configure('qa-recovery');
              final linked = await h.seedLinked();
              staged = linked.copy(
                status: BankConnectionStatus.awaitingImport,
                remoteConnectionId: null,
                pendingRemoteConnectionId: 'qa-session-A',
                pendingAuthorizationId: 'qa-pending',
                pendingValidUntil: h.clock().add(const Duration(days: 30)),
              );
              await h.db.update(
                'bankConnection',
                staged.toJson(),
                where: 'id = ?',
                whereArgs: [staged.id],
              );
              await h.seedPending();
              await h.pending.save(
                (await h.pending.read())!.copy(
                  stagedConnectionId: staged.id,
                  phase: PendingAuthorizationPhase.connectionStaged,
                ),
              );
              history = await h.db.query('transaction');
            });
            await h.mount(tester);
            fault.fail = true;
            final flow = h.container.read(connectBankFlowProvider.notifier);
            final result = (await tester.runAsync(
              () => local
                  ? flow.disconnectLocally(staged)
                  : flow.disconnect(staged),
            ))!;
            expect(result.applied, isTrue);
            expect(
              result.message,
              local
                  ? contains('Remote consent was not revoked')
                  : contains('Remote access is closed'),
            );
            expect(
              h.container.read(bankRecoveryIssueProvider),
              contains('cleanup'),
            );
            expect(h.deletes, local ? 0 : 1);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(h.reopen);
            await h.mount(tester);
            expect(
              h.container.read(connectBankFlowProvider).authorizationOwner,
              isNull,
            );
            expect(
              h.container.read(connectBankFlowProvider).pendingCleanup,
              isNotNull,
            );
            expect(find.text('Retry cleanup'), findsOneWidget);
            final replacement = PendingBankAuthorization.fromJson({
              ...result.pendingCleanup!.toJson(),
              'state': 'independent-B',
              'authorization_id': 'independent-B',
              'aspsp_name': 'Bank B',
              'staged_connection_id': null,
              'phase': 'awaitingCallback',
            });
            fault.fail = false;
            await tester.runAsync(() => h.pending.save(replacement));
            await tester.tap(find.text('Retry cleanup'));
            await pumpRecoveryUntil(
              tester,
              () =>
                  h.container
                      .read(connectBankFlowProvider)
                      .authorizationOwner
                      ?.pending
                      ?.state ==
                  replacement.state,
            );
            expect(
              (await tester.runAsync(h.pending.read))!.toJson(),
              replacement.toJson(),
            );
            expect(
              await tester.runAsync(() => h.db.query('transaction')),
              history,
            );
            expect(
              (await tester.runAsync(
                () => h.db.query('bankAccount'),
              ))!.single[BankAccountFields.ebConnectionId],
              isNull,
            );
            expect(
              (await tester.runAsync(
                () => h.repository.selectById(staged.id!),
              ))!.status,
              local
                  ? BankConnectionStatus.disconnected
                  : BankConnectionStatus.revoked,
            );
            expect(h.deletes, local ? 0 : 1);
          } finally {
            fault.fail = false;
            await h.close(tester);
          }
        },
  'RECOVERY contract cancel POST then another bank without late launch':
      (tester) async {
        final h = BankingRecoveryActionsHarness(
          factory: factory,
          storage: storage,
        );
        try {
          await tester.runAsync(() async {
            await h.open();
            await h.configure('qa-recovery');
          });
          await h.mount(tester);
          h.authEntered = Completer<void>();
          h.authGate = Completer<void>();
          final flow = h.container.read(connectBankFlowProvider.notifier);
          final first = flow.startConnection(
            h.institution('Bank A'),
            launcher: h.launch,
          );
          final rejected = expectLater(first, throwsA(anything));
          await pumpRecoveryUntil(tester, () => h.authEntered!.isCompleted);
          await tester.tap(find.text('Cancel attempt'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Cancel attempt').last);
          await pumpRecoveryUntil(
            tester,
            () =>
                h.container.read(connectBankFlowProvider).authorizationOwner ==
                null,
          );
          h.authGate!.complete();
          await rejected;
          h.authGate = null;
          h.authEntered = null;
          final next = await tester.runAsync(
            () => flow.startConnection(
              h.institution('Bank B'),
              launcher: h.launch,
            ),
          );
          expect(next!.opened, isFalse);
          expect(
            (await tester.runAsync(h.pending.read))!.institutionName,
            'Bank B',
          );
          expect(h.launches, 1);
          expect(h.deletes, 0);
        } finally {
          await h.close(tester);
        }
      },
  'RECOVERY contract cancel pending reopen and negative Back preserve stored owner':
      (tester) async {
        final h = BankingRecoveryActionsHarness(
          factory: factory,
          storage: storage,
        );
        try {
          await tester.runAsync(() async {
            await h.open();
            await h.seedPending();
            await h.reopen();
          });
          await h.mount(tester);
          expect(find.text('Waiting for bank authorization'), findsOneWidget);
          await tester.tap(find.text('Cancel attempt'));
          await tester.pumpAndSettle();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(await tester.runAsync(h.pending.read), isNotNull);
          expect(h.deletes, 0);
          await tester.tap(find.text('Cancel attempt'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Cancel attempt').last);
          await pumpRecoveryUntil(
            tester,
            () =>
                h.container
                    .read(connectBankFlowProvider)
                    .recoveryNotice
                    ?.applied ==
                true,
          );
          expect(await tester.runAsync(h.pending.read), isNull);
          expect(h.deletes, 0);
        } finally {
          await h.close(tester);
        }
      },
  'RECOVERY contract cancel stale dialog preserves newer pending B':
      (tester) async {
        final h = BankingRecoveryActionsHarness(
          factory: factory,
          storage: storage,
        );
        try {
          await tester.runAsync(() async {
            await h.open();
            await h.configure('qa-recovery');
            await h.seedPending();
          });
          await h.mount(tester);
          await tester.tap(find.text('Cancel attempt'));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await h.container
                .read(bankConsentLifecycleServiceProvider)
                .cancelAuthorization();
            await h.container
                .read(connectBankFlowProvider.notifier)
                .startConnection(h.institution('Bank B'), launcher: h.launch);
          });
          await tester.tap(find.text('Cancel attempt').last);
          await pumpRecoveryUntil(
            tester,
            () =>
                h.container
                    .read(connectBankFlowProvider)
                    .recoveryNotice
                    ?.status ==
                BankRecoveryActionStatus.stale,
          );
          expect(
            (await tester.runAsync(h.pending.read))!.institutionName,
            'Bank B',
          );
          expect(find.text(bankRecoveryStaleMessage), findsOneWidget);
          expect(h.deletes, 0);
        } finally {
          await h.close(tester);
        }
      },
  for (final credentials in [null, 'other-app'])
    'RECOVERY contract local credentials=$credentials decline then preserve manual history':
        (tester) async {
          final h = BankingRecoveryActionsHarness(
            factory: factory,
            storage: storage,
          );
          try {
            late List<Map<String, Object?>> history;
            await tester.runAsync(() async {
              await h.open();
              await h.seedLinked();
              if (credentials != null) await h.configure(credentials);
              history = await h.db.query('transaction');
            });
            await h.mount(tester);
            expect(
              find.text('CONFIGURE'),
              credentials == null ? findsOneWidget : findsNothing,
            );
            await tester.ensureVisible(find.text('Disconnect locally'));
            await tester.tap(find.text('Disconnect locally'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Keep connection'));
            await tester.pumpAndSettle();
            expect(
              (await tester.runAsync(
                () => h.repository.selectAll(),
              ))!.single.status,
              BankConnectionStatus.active,
            );
            await tester.tap(find.text('Disconnect locally'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Disconnect locally').last);
            await pumpRecoveryUntil(
              tester,
              () =>
                  h.container
                          .read(connectBankFlowProvider)
                          .recoveryNotice
                          ?.applied ==
                      true &&
                  !h.container.read(bankConnectionsProvider).isLoading,
            );
            expect(h.deletes, 0);
            expect(
              await tester.runAsync(() => h.db.query('transaction')),
              history,
            );
            expect(
              (await tester.runAsync(
                () => h.db.query('bankAccount'),
              ))!.single[BankAccountFields.ebConnectionId],
              isNull,
            );
            expect(
              find.textContaining(
                'Remote consent was not revoked by this action',
              ),
              findsOneWidget,
            );
          } finally {
            await h.close(tester);
          }
        },
  'RECOVERY contract local stale dialog preserves reconnect B on same id':
      (tester) async {
        final h = BankingRecoveryActionsHarness(
          factory: factory,
          storage: storage,
        );
        try {
          late BankConnection a;
          await tester.runAsync(() async {
            await h.open();
            a = await h.seedLinked();
          });
          await h.mount(tester);
          await tester.ensureVisible(find.text('Disconnect locally'));
          await tester.tap(find.text('Disconnect locally'));
          await tester.pumpAndSettle();
          final b = a.copy(remoteConnectionId: 'session-B');
          await tester.runAsync(
            () => h.db.update(
              'bankConnection',
              b.toJson(),
              where: 'id = ?',
              whereArgs: [a.id],
            ),
          );
          await tester.tap(find.text('Disconnect locally').last);
          await pumpRecoveryUntil(
            tester,
            () => h.container
                .read(connectBankFlowProvider)
                .recoveryActions
                .any((item) => item.status == BankRecoveryActionStatus.stale),
          );
          expect(
            (await tester.runAsync(
              () => h.repository.selectById(a.id!),
            ))!.sameLifecycle(b),
            isTrue,
          );
          expect(
            h.container.read(connectBankFlowProvider).recoveryNotice?.status,
            BankRecoveryActionStatus.stale,
          );
          expect(find.text(bankRecoveryStaleMessage), findsOneWidget);
          expect(h.deletes, 0);
        } finally {
          await h.close(tester);
        }
      },
};
