import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_account_link.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/services/banking/bank_institution_directory.dart';
import 'package:sossoldi/services/banking/bank_institution.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_auth.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_consent_service.dart';
import 'package:sossoldi/services/banking/bank_authorization_context.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_callback.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_coordinator.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_consent_lifecycle_service.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_session_recovery_store.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Auth extends EnableBankingAuth {
  @override
  Future<String> getValidToken(EnableBankingCredentialsStore store) async =>
      'synthetic';
}

class _RecoveryBackend extends FlutterSecureStorage {}

class _InterruptedClaimRepository extends BankConnectionRepository {
  _InterruptedClaimRepository(super.database) : super.withDatabase();

  @override
  Future<BankConnection?> markStatusIfCurrent(
    BankConnection expected,
    BankConnectionStatus status, {
    DateTime Function()? clock,
  }) async {
    final changed = await super.markStatusIfCurrent(
      expected,
      status,
      clock: clock,
    );
    if (changed != null && status == BankConnectionStatus.revocationPending) {
      throw StateError('synthetic interruption after committed claim');
    }
    return changed;
  }
}

class _Directory implements BankInstitutionDirectory {
  @override
  Future<List<BankInstitution>> getInstitutions({
    String? country,
    BankingCustomerType customerType = BankingCustomerType.personal,
  }) async => [];
}

class _FaultJournal implements BankSessionRecoveryStore {
  final BankSessionRecoveryStore backend;
  _FaultJournal(FlutterSecureStorage storage)
    : backend = SecureBankSessionRecoveryStore(storage: storage);
  bool failStarted = false;
  bool failKnown = false;
  bool failRead = false;
  bool failRemove = false;
  Completer<void>? retiredEntered;
  Completer<void>? retiredGate;
  @override
  Future<List<BankSessionRecoveryRecord>> read() async {
    if (failRead) throw const BankSessionRecoveryStorageException();
    return backend.read();
  }

  @override
  Future<bool> upsert(
    BankSessionRecoveryRecord record, {
    BankSessionRecoveryRecord? expected,
  }) async {
    if ((failStarted &&
            record.phase == BankSessionRecoveryPhase.exchangeStarted) ||
        (failKnown && record.remoteConnectionId != null)) {
      throw const BankSessionRecoveryStorageException();
    }
    final result = await backend.upsert(record, expected: expected);
    if (record.authorizationId.startsWith('retired:')) {
      retiredEntered?.complete();
      await retiredGate?.future;
    }
    return result;
  }

  @override
  Future<bool> removeIfCurrent(BankSessionRecoveryRecord record) async {
    if (failRemove) throw const BankSessionRecoveryStorageException();
    return backend.removeIfCurrent(record);
  }
}

class _FaultPending extends SecurePendingBankAuthorizationStore {
  _FaultPending({super.storage});
  bool failSave = false;
  bool failCleanup = false;
  Completer<void>? readEntered;
  Completer<void>? readGate;
  @override
  Future<PendingBankAuthorization?> read() async {
    final value = await super.read();
    final gate = readGate;
    if (readEntered != null && !readEntered!.isCompleted) {
      readEntered!.complete();
      readGate = null;
      await gate?.future;
    }
    return value;
  }

  @override
  Future<void> save(PendingBankAuthorization pending) async {
    if (failSave) throw StateError('synthetic pending write');
    await super.save(pending);
  }

  @override
  Future<void> saveObsoleteConnection(ObsoleteBankConnection reference) async {
    if (failCleanup) throw StateError('synthetic legacy cleanup write');
    await super.saveObsoleteConnection(reference);
  }
}

void main() {
  final now = DateTime.utc(2032, 3, 28, 12);
  late _FaultPending pendingStore;
  late _FaultJournal journal;
  late Database db;
  late Directory temp;
  late BankConnectionRepository repository;
  var owner = 'A';
  var postCalls = 0;
  var deletes = 0;
  var deleteFails = false;
  final deletedIds = <String>[];
  Completer<void>? deleteEntered;
  Completer<void>? deleteGate;
  Completer<void>? postEntered;
  Completer<void>? postGate;
  Object payload = {'session_id': 'known', 'accounts': 'malformed'};
  Future<void> reopen() async {
    final manager = MigrationManager();
    db = await databaseFactoryFfi.openDatabase(
      '${temp.path}/existing-v9.db',
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onCreate: (db, version) => manager.migrate(db, 0, version),
      ),
    );
    repository = BankConnectionRepository.withDatabase(db);
  }

  BankConsentLifecycleService service({bool includeJournal = true}) {
    final api = EnableBankingApi(
      auth: _Auth(),
      store: const EnableBankingCredentialsStore(),
      client: MockClient((request) async {
        if (request.method == 'POST') {
          postCalls++;
          postEntered?.complete();
          await postGate?.future;
          return http.Response(
            payload is String ? payload as String : jsonEncode(payload),
            200,
          );
        }
        deletes++;
        deletedIds.add(request.url.path);
        deleteEntered?.complete();
        await deleteGate?.future;
        return http.Response('{}', deleteFails ? 500 : 204);
      }),
    );
    return BankConsentLifecycleService(
      consent: EnableBankingConsentService(api),
      institutions: _Directory(),
      readContext: () async => BankAuthorizationContext(
        providerId: 'enable_banking',
        applicationId: owner,
        redirectUri: 'sossoldi://eb-callback',
      ),
      pendingStore: pendingStore,
      recoveryStore: includeJournal ? journal : null,
      connections: repository,
      clock: () => now,
    );
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    final backend = _RecoveryBackend();
    pendingStore = _FaultPending(storage: backend);
    journal = _FaultJournal(backend);
    sqfliteFfiInit();
    temp = Directory.systemTemp.createTempSync('bank-session-recovery-');
    await reopen();
    owner = 'A';
    postCalls = 0;
    deletes = 0;
    deleteFails = false;
    deletedIds.clear();
    deleteEntered = null;
    deleteGate = null;
    postEntered = null;
    postGate = null;
    payload = {'session_id': 'known', 'accounts': 'malformed'};
    await pendingStore.save(
      PendingBankAuthorization(
        providerId: 'enable_banking',
        state: 'synthetic-state',
        authorizationId: 'auth',
        authorizationUrl: 'https://bank.example',
        applicationId: 'A',
        institutionName: 'Test Bank',
        institutionCountry: 'IT',
        redirectUri: 'sossoldi://eb-callback',
        expiresAt: now.add(const Duration(minutes: 15)),
        consentValidUntil: now.add(const Duration(days: 90)),
      ),
    );
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  const callback = BankAuthorizationCallback(
    state: 'synthetic-state',
    code: 'synthetic-code',
  );
  Map<String, Object?> validPayload() => {
    'session_id': 'known',
    'aspsp': {'name': 'Test Bank', 'country': 'IT'},
    'psu_type': 'personal',
    'access': {
      'valid_until': now.add(const Duration(days: 90)).toIso8601String(),
    },
    'accounts': [
      {'uid': 'uid', 'currency': 'EUR', 'identification_hash': 'hash'},
    ],
  };

  for (final boundary in ['read', 'intent']) {
    test('failed journal $boundary prevents POST dispatch', () async {
      journal.failRead = boundary == 'read';
      journal.failStarted = boundary == 'intent';
      await expectLater(
        service().completeCallback(callback),
        throwsA(isA<BankSessionRecoveryStorageException>()),
      );
      expect(postCalls, 0);
    });
  }
  final draft = const BankAccount(
    name: 'Imported',
    symbol: 'wallet',
    color: 1,
    startingValue: 0,
    active: true,
    countNetWorth: true,
    mainAccount: true,
    order: 0,
  );
  for (final source in ['journal', 'legacy']) {
    for (final originalStatus in [
      BankConnectionStatus.active,
      BankConnectionStatus.expired,
      BankConnectionStatus.reauthRequired,
      BankConnectionStatus.revocationPending,
    ]) {
      for (final interruption in ['delete', 'claim']) {
        test(
          'durable cleanup restores ${originalStatus.name} after $interruption interruption from $source',
          () async {
            final staged = await repository.insert(
              BankConnection(
                providerId: 'enable_banking',
                applicationId: 'A',
                institutionName: 'Test Bank',
                institutionCountry: 'IT',
                remoteConnectionId: 'old-session',
                validUntil: originalStatus == BankConnectionStatus.expired
                    ? now.subtract(const Duration(days: 1))
                    : now.add(const Duration(days: 1)),
                pendingRemoteConnectionId: 'orphan-session',
                pendingAuthorizationId: 'orphan-auth',
                pendingValidUntil: now.add(const Duration(days: 90)),
                status: originalStatus,
              ),
            );
            await pendingStore.clear();
            if (source == 'journal') {
              await journal.upsert(
                BankSessionRecoveryRecord(
                  providerId: 'enable_banking',
                  applicationId: 'A',
                  authorizationId: 'orphan-auth',
                  remoteConnectionId: 'orphan-session',
                  phase: BankSessionRecoveryPhase.knownSession,
                  updatedAt: now,
                ),
              );
            } else {
              await pendingStore.saveObsoleteConnection(
                const ObsoleteBankConnection(
                  providerId: 'enable_banking',
                  applicationId: 'A',
                  authorizationId: 'orphan-auth',
                  remoteConnectionId: 'orphan-session',
                  attemptRevision: 0,
                  reason: 'legacy-cleanup',
                ),
              );
            }
            if (interruption == 'claim') {
              repository = _InterruptedClaimRepository(db);
              await expectLater(service().recoverSessions(), throwsStateError);
              expect(deletes, 0);
            } else {
              deleteFails = true;
              expect((await service().recoverSessions()).retryFailed, 1);
              expect(deletes, 1);
            }
            expect(
              (await repository.selectById(staged.id!)).status,
              BankConnectionStatus.revocationPending,
            );
            expect((await journal.read()).single.restoreStatus, originalStatus);
            await db.close();
            await reopen();
            deleteFails = false;
            expect((await service().recoverSessions()).cleanupConfirmed, 1);
            final restored = await repository.selectById(staged.id!);
            expect(restored.status, originalStatus);
            expect(restored.remoteConnectionId, 'old-session');
            expect(restored.validUntil, staged.validUntil);
            expect(restored.pendingRemoteConnectionId, isNull);
            expect(await journal.read(), isEmpty);
            expect(await pendingStore.readObsoleteConnections(), isEmpty);
            expect(deletedIds, everyElement('/sessions/orphan-session'));
          },
        );
      }
    }
  }
  for (final source in ['journal', 'legacy']) {
    test(
      'failed restoration metadata write prevents claim and DELETE from $source',
      () async {
        final staged = await repository.insert(
          BankConnection(
            providerId: 'enable_banking',
            applicationId: 'A',
            institutionName: 'Test Bank',
            institutionCountry: 'IT',
            remoteConnectionId: 'old-session',
            validUntil: now.add(const Duration(days: 1)),
            pendingRemoteConnectionId: 'orphan-session',
            pendingAuthorizationId: 'orphan-auth',
            pendingValidUntil: now.add(const Duration(days: 90)),
            status: BankConnectionStatus.active,
          ),
        );
        await pendingStore.clear();
        if (source == 'journal') {
          await journal.upsert(
            BankSessionRecoveryRecord(
              providerId: 'enable_banking',
              applicationId: 'A',
              authorizationId: 'orphan-auth',
              remoteConnectionId: 'orphan-session',
              phase: BankSessionRecoveryPhase.knownSession,
              updatedAt: now,
            ),
          );
        } else {
          await pendingStore.saveObsoleteConnection(
            const ObsoleteBankConnection(
              providerId: 'enable_banking',
              applicationId: 'A',
              authorizationId: 'orphan-auth',
              remoteConnectionId: 'orphan-session',
              attemptRevision: 0,
              reason: 'legacy-cleanup',
            ),
          );
        }
        journal.failKnown = true;
        await expectLater(
          service().recoverSessions(),
          throwsA(isA<BankSessionRecoveryStorageException>()),
        );
        expect(
          (await repository.selectById(staged.id!)).sameLifecycle(staged),
          isTrue,
        );
        expect(deletes, 0);
        journal.failKnown = false;
        expect((await service().recoverSessions()).cleanupConfirmed, 1);
        expect(
          (await repository.selectById(staged.id!)).status,
          BankConnectionStatus.active,
        );
      },
    );
  }
  test(
    'legacy service without restoration journal does not claim live staging',
    () async {
      final staged = await repository.insert(
        BankConnection(
          providerId: 'enable_banking',
          applicationId: 'A',
          institutionName: 'Test Bank',
          institutionCountry: 'IT',
          remoteConnectionId: 'old-session',
          validUntil: now.add(const Duration(days: 1)),
          pendingRemoteConnectionId: 'orphan-session',
          pendingAuthorizationId: 'orphan-auth',
          pendingValidUntil: now.add(const Duration(days: 90)),
          status: BankConnectionStatus.active,
        ),
      );
      await pendingStore.clear();
      await pendingStore.saveObsoleteConnection(
        const ObsoleteBankConnection(
          providerId: 'enable_banking',
          applicationId: 'A',
          authorizationId: 'orphan-auth',
          remoteConnectionId: 'orphan-session',
          attemptRevision: 0,
          reason: 'legacy-cleanup',
        ),
      );
      final report = await service(includeJournal: false).recoverSessions();
      expect(report.retryFailed, 1);
      expect(report.notPersisted, 0);
      expect(
        (await repository.selectById(staged.id!)).sameLifecycle(staged),
        isTrue,
      );
      expect(deletes, 0);
      expect(await pendingStore.readObsoleteConnections(), hasLength(1));
    },
  );
  test(
    'EB-EDGE-37 reconnect retains old session through failed cleanup and restart',
    () async {
      final old = await repository.insert(
        BankConnection(
          providerId: 'enable_banking',
          applicationId: 'A',
          institutionName: 'Test Bank',
          institutionCountry: 'IT',
          remoteConnectionId: 'old-session',
          validUntil: now.add(const Duration(days: 1)),
          status: BankConnectionStatus.active,
        ),
      );
      await pendingStore.save(
        PendingBankAuthorization.fromJson({
          ...((await pendingStore.read())!.toJson()),
          'reconnect_connection_id': old.id,
        }),
      );
      payload = validPayload();
      final staged = await service().completeCallback(callback);
      deleteFails = true;
      final active = await service().activateConnection(staged.connection.id!, [
        (remote: staged.createdConnection!.accounts.single, newAccount: draft),
      ], expectedStaging: staged.connection);
      expect(active.remoteConnectionId, 'known');
      expect(deletedIds, ['/sessions/old-session']);
      expect((await journal.read()).single.remoteConnectionId, 'old-session');
      await db.close();
      await reopen();
      deleteFails = false;
      expect((await service().recoverSessions()).cleanupConfirmed, 1);
      expect(
        (await repository.selectById(active.id!)).remoteConnectionId,
        'known',
      );
      expect(deletedIds, ['/sessions/old-session', '/sessions/old-session']);
      expect(await journal.read(), isEmpty);
    },
  );
  test(
    'recovery waits for retired receipt plus activation commit before deciding cleanup',
    () async {
      final old = await repository.insert(
        BankConnection(
          providerId: 'enable_banking',
          applicationId: 'A',
          institutionName: 'Test Bank',
          institutionCountry: 'IT',
          remoteConnectionId: 'old-session',
          validUntil: now.add(const Duration(days: 1)),
          status: BankConnectionStatus.active,
        ),
      );
      await pendingStore.save(
        PendingBankAuthorization.fromJson({
          ...((await pendingStore.read())!.toJson()),
          'reconnect_connection_id': old.id,
        }),
      );
      payload = validPayload();
      final staged = await service().completeCallback(callback);
      journal.retiredEntered = Completer<void>();
      journal.retiredGate = Completer<void>();
      final activation = service().activateConnection(old.id!, [
        (remote: staged.createdConnection!.accounts.single, newAccount: draft),
      ], expectedStaging: staged.connection);
      await journal.retiredEntered!.future;
      final recovery = service().recoverSessions();
      journal.retiredGate!.complete();
      await activation;
      await recovery;
      expect(deletedIds, ['/sessions/old-session']);
      expect(
        (await repository.selectById(old.id!)).remoteConnectionId,
        'known',
      );
    },
  );
  test(
    'recovery rechecks SQL after delayed pending read before DELETE',
    () async {
      payload = validPayload();
      final staged = await service().completeCallback(callback);
      pendingStore.readEntered = Completer<void>();
      final gate = Completer<void>();
      pendingStore.readGate = gate;
      final recovery = service().recoverSessions();
      await pendingStore.readEntered!.future;
      await repository.activateStagedConnection(
        staged.connection.id!,
        [
          BankAccountLink(
            uid: 'uid',
            identificationHashes: const {'hash'},
            newAccount: draft,
          ),
        ],
        expectedStaging: staged.connection,
        clock: () => now,
      );
      await pendingStore.clear();
      gate.complete();
      await recovery;
      expect(deletes, 0);
      await service().recoverSessions();
      expect(deletes, 0);
      expect(await journal.read(), isEmpty);
    },
  );
  test(
    'cleanup claims staging before DELETE so activation cannot race remote revocation',
    () async {
      payload = validPayload();
      final staged = await service().completeCallback(callback);
      await pendingStore.clear();
      deleteEntered = Completer<void>();
      deleteGate = Completer<void>();
      final recovery = service().recoverSessions();
      await deleteEntered!.future;
      expect(
        (await repository.selectById(staged.connection.id!)).status,
        BankConnectionStatus.revocationPending,
      );
      await expectLater(
        repository.activateStagedConnection(
          staged.connection.id!,
          [
            BankAccountLink(
              uid: 'uid',
              identificationHashes: const {'hash'},
              newAccount: draft,
            ),
          ],
          expectedStaging: staged.connection,
          clock: () => now,
        ),
        throwsA(anything),
      );
      deleteGate!.complete();
      await recovery;
      expect(await db.query(bankAccountTable), isEmpty);
      expect(
        (await repository.selectById(staged.connection.id!)).status,
        BankConnectionStatus.revoked,
      );
    },
  );
  for (final malformed in [
    'accounts',
    'uid',
    'access',
    'validUntil',
    'mapper',
  ]) {
    test(
      'D06 real adapter captures known ID before malformed $malformed',
      () async {
        final value = validPayload();
        switch (malformed) {
          case 'accounts':
            value['accounts'] = 'invalid';
          case 'uid':
            value['accounts'] = [
              {'uid': 7, 'currency': 'EUR'},
            ];
          case 'access':
            value['access'] = 'invalid';
          case 'validUntil':
            value['access'] = {'valid_until': 'invalid'};
          case 'mapper':
            value['aspsp'] = {'name': '', 'country': ''};
        }
        payload = value;
        deleteFails = true;
        await expectLater(
          service().completeCallback(callback),
          throwsA(
            isA<ObsoleteBankAuthorizationException>()
                .having(
                  (error) => error.connection.remoteConnectionId,
                  'known ID',
                  'known',
                )
                .having((error) => error.referencePersisted, 'durable', isTrue),
          ),
        );
        expect(postCalls, 1);
        expect((await journal.read()).single.remoteConnectionId, 'known');
      },
    );
  }
  for (final cleanupFails in [false, true]) {
    test(
      'receipt and legacy persistence fail cleanupFails=$cleanupFails reports actual durability',
      () async {
        journal.failKnown = true;
        pendingStore.failCleanup = true;
        deleteFails = cleanupFails;
        await expectLater(
          service().completeCallback(callback),
          throwsA(
            isA<ObsoleteBankAuthorizationException>()
                .having(
                  (error) => error.cleanupConfirmed,
                  'DELETE confirmed',
                  !cleanupFails,
                )
                .having(
                  (error) => error.referencePersisted,
                  'known reference durable',
                  isFalse,
                )
                .having(
                  (error) => error.connection.remoteConnectionId,
                  'reference in process',
                  'known',
                ),
          ),
        );
        expect(postCalls, 1);
        if (cleanupFails) {
          expect((await journal.read()).single.remoteConnectionId, isNull);
        } else {
          expect(await journal.read(), isEmpty);
        }
      },
    );
  }
  for (final boundary in ['sql', 'pending']) {
    test(
      'failure after remote session at $boundary is compensated and retried after reopen',
      () async {
        payload = validPayload();
        deleteFails = true;
        if (boundary == 'sql') {
          await db.execute(
            'CREATE TRIGGER reject_stage BEFORE INSERT ON bankConnection BEGIN SELECT RAISE(ABORT, \'synthetic\'); END',
          );
        }
        if (boundary == 'pending') pendingStore.failSave = true;
        await expectLater(
          service().completeCallback(callback),
          throwsA(
            isA<ObsoleteBankAuthorizationException>().having(
              (error) => error.referencePersisted,
              'durable reference',
              isTrue,
            ),
          ),
        );
        await db.close();
        await reopen();
        deleteFails = false;
        expect((await service().recoverSessions()).cleanupConfirmed, 1);
        expect(postCalls, 1);
        expect(deletes, 2);
        expect(await journal.read(), isEmpty);
      },
    );
  }
  test(
    'staged receipt after crash restores pending and never revokes valid active session',
    () async {
      payload = validPayload();
      final first = await service().completeCallback(callback);
      await db.close();
      await reopen();
      final duplicate = await service().completeCallback(callback);
      expect(duplicate.connection.id, first.connection.id);
      expect(postCalls, 1);
      expect((await service().recoverSessions()).cleanupConfirmed, 0);
      expect(deletes, 0);
      expect(await journal.read(), isEmpty);
    },
  );
  test(
    'Cancel and app replacement preserve receipt without using old credentials',
    () async {
      postEntered = Completer<void>();
      postGate = Completer<void>();
      final running = service();
      final operation = running.completeCallback(callback);
      final rejected = expectLater(
        operation,
        throwsA(
          isA<ObsoleteBankAuthorizationException>().having(
            (error) => error.referencePersisted,
            'durable reference',
            isTrue,
          ),
        ),
      );
      await postEntered!.future;
      await running.cancelAuthorization();
      owner = 'B';
      postGate!.complete();
      await rejected;
      expect(deletes, 0);
      expect((await service().recoverSessions()).ownerUnavailable, 1);
      owner = 'A';
      expect((await service().recoverSessions()).cleanupConfirmed, 1);
      expect(await pendingStore.read(), isNull);
    },
  );
  test('DELETE success with failed journal removal stays retryable', () async {
    deleteFails = true;
    await expectLater(service().completeCallback(callback), throwsA(anything));
    deleteFails = false;
    journal.failRemove = true;
    expect((await service().recoverSessions()).retryFailed, 1);
    expect(await journal.read(), hasLength(1));
    journal.failRemove = false;
    expect((await service().recoverSessions()).cleanupConfirmed, 1);
    expect(await journal.read(), isEmpty);
  });
  test(
    'D06 real adapter malformed DTO retains receipt and restart retries cleanup owner safely',
    () async {
      deleteFails = true;
      await expectLater(
        service().completeCallback(
          const BankAuthorizationCallback(
            state: 'synthetic-state',
            code: 'synthetic-code',
          ),
        ),
        throwsA(
          isA<ObsoleteBankAuthorizationException>().having(
            (error) => error.referencePersisted,
            'persisted',
            isTrue,
          ),
        ),
      );
      expect(postCalls, 1);
      expect((await journal.read()).single.remoteConnectionId, 'known');
      await db.close();
      await reopen();
      owner = 'B';
      deleteFails = false;
      expect((await service().recoverSessions()).ownerUnavailable, 1);
      expect(deletes, 1);
      owner = 'A';
      expect((await service().recoverSessions()).cleanupConfirmed, 1);
      expect(deletes, 2);
      expect(await journal.read(), isEmpty);
      expect(await pendingStore.readObsoleteConnections(), isEmpty);
    },
  );
  test(
    'truncated response remains unknown across restart without POST replay',
    () async {
      payload = '{';
      final callback = const BankAuthorizationCallback(
        state: 'synthetic-state',
        code: 'synthetic-code',
      );
      await expectLater(
        service().completeCallback(callback),
        throwsA(isA<BankSessionOutcomeUnknownException>()),
      );
      await db.close();
      await reopen();
      expect((await service().recoverSessions()).unknown, 1);
      await expectLater(
        service().completeCallback(callback),
        throwsA(isA<BankSessionOutcomeUnknownException>()),
      );
      expect(postCalls, 1);
      expect(deletes, 0);
    },
  );
}
