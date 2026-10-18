import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_session_recovery_store.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_credentials_store.dart';

class _FaultStorage extends FlutterSecureStorage {
  var failRead = false;
  var failWrite = false;
  var failDelete = false;
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failRead) throw StateError('synthetic read');
    return super.read(key: key);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrite) throw StateError('synthetic write');
    await super.write(key: key, value: value);
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failDelete) throw StateError('synthetic delete');
    await super.delete(key: key);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'legacy journal remains readable and restore status participates in CAS',
    () async {
      const store = SecureBankSessionRecoveryStore();
      final legacy = BankSessionRecoveryRecord.fromJson({
        'provider': 'provider',
        'application': 'app',
        'authorization': 'authorization',
        'remote': 'known',
        'phase': 'cleanupRequired',
        'updated': '2032-01-01T00:00:00Z',
      });
      expect(legacy.restoreStatus, isNull);
      await store.upsert(legacy);
      for (final status in [
        BankConnectionStatus.active,
        BankConnectionStatus.expired,
        BankConnectionStatus.reauthRequired,
        BankConnectionStatus.revocationPending,
      ]) {
        final expected = (await store.read()).single;
        final claimed = expected.copy(restoreStatus: status);
        expect(await store.upsert(claimed, expected: expected), isTrue);
        expect(
          (await const SecureBankSessionRecoveryStore().read())
              .single
              .restoreStatus,
          status,
        );
        expect(await store.removeIfCurrent(legacy), isFalse);
        expect(
          BankSessionRecoveryRecord.fromJson(
            claimed.toJson(),
          ).sameVersion(claimed),
          isTrue,
        );
      }
      await const FlutterSecureStorage().write(
        key: 'bank_session_recovery_v1',
        value:
            '{"version":1,"records":[{"provider":"provider","application":"app","authorization":"authorization","remote":"known","phase":"cleanupRequired","updated":"2032-01-01T00:00:00Z","restore_status":"UNKNOWN"}]}',
      );
      await expectLater(
        store.read(),
        throwsA(isA<BankSessionRecoveryStorageException>()),
      );
    },
  );
  test(
    'read write and delete failures preserve records and stay observable',
    () async {
      final backend = _FaultStorage();
      final store = SecureBankSessionRecoveryStore(storage: backend);
      final record = BankSessionRecoveryRecord(
        providerId: 'provider',
        applicationId: 'app',
        authorizationId: 'authorization',
        phase: BankSessionRecoveryPhase.knownSession,
        remoteConnectionId: 'known',
        updatedAt: DateTime.utc(2032),
      );
      backend.failWrite = true;
      await expectLater(
        store.upsert(record),
        throwsA(isA<BankSessionRecoveryStorageException>()),
      );
      backend.failWrite = false;
      expect(await store.read(), isEmpty);
      await store.upsert(record);
      backend.failRead = true;
      await expectLater(
        store.removeIfCurrent(record),
        throwsA(isA<BankSessionRecoveryStorageException>()),
      );
      backend.failRead = false;
      backend.failDelete = true;
      await expectLater(
        store.removeIfCurrent(record),
        throwsA(isA<BankSessionRecoveryStorageException>()),
      );
      backend.failDelete = false;
      expect((await store.read()).single.sameVersion(record), isTrue);
      expect(await store.removeIfCurrent(record), isTrue);
    },
  );
  test(
    'journal is independent of pending credentials and legacy cleanup',
    () async {
      const store = SecureBankSessionRecoveryStore();
      final record = BankSessionRecoveryRecord(
        providerId: 'provider',
        applicationId: 'app',
        authorizationId: 'authorization',
        phase: BankSessionRecoveryPhase.knownSession,
        remoteConnectionId: 'known',
        updatedAt: DateTime.utc(2032),
      );
      await store.upsert(record);
      await const SecurePendingBankAuthorizationStore().clear();
      await const EnableBankingCredentialsStore().clear();
      final encoded = (await const FlutterSecureStorage().read(
        key: 'bank_session_recovery_v1',
      ))!;
      for (final secret in [
        'state',
        'code',
        'url',
        'pem',
        'jwt',
        'accounts',
        'private',
      ]) {
        expect(encoded.toLowerCase(), isNot(contains(secret)));
      }
      expect(
        (await const SecureBankSessionRecoveryStore().read()).single
            .sameVersion(record),
        isTrue,
      );
    },
  );
  test(
    'journal serializes owners and removes only the expected version',
    () async {
      const backend = FlutterSecureStorage();
      const a = SecureBankSessionRecoveryStore(storage: backend);
      const b = SecureBankSessionRecoveryStore(storage: backend);
      final started = BankSessionRecoveryRecord(
        providerId: 'provider',
        applicationId: 'A',
        authorizationId: 'authorization',
        phase: BankSessionRecoveryPhase.exchangeStarted,
        updatedAt: DateTime.utc(2032),
      );
      final other = BankSessionRecoveryRecord(
        providerId: 'provider',
        applicationId: 'B',
        authorizationId: 'authorization',
        phase: BankSessionRecoveryPhase.cleanupRequired,
        remoteConnectionId: 'B-session',
        updatedAt: DateTime.utc(2032),
      );
      await Future.wait([a.upsert(started), b.upsert(other)]);
      final records = await b.read();
      expect(records, hasLength(2));
      expect(records.first.phase, BankSessionRecoveryPhase.outcomeUnknown);
      final known = records.first.copy(
        phase: BankSessionRecoveryPhase.knownSession,
        remoteConnectionId: 'A-session',
        updatedAt: DateTime.utc(2032, 1, 2),
      );
      await a.upsert(known, expected: records.first);
      expect(await b.removeIfCurrent(records.first), isFalse);
      expect(await b.removeIfCurrent(known), isTrue);
      expect((await a.read()).single.applicationId, 'B');
    },
  );
  test('corrupt and unknown journal versions fail closed', () async {
    FlutterSecureStorage.setMockInitialValues({
      'bank_session_recovery_v1': '{"version":2,"records":[]}',
    });
    await expectLater(
      const SecureBankSessionRecoveryStore().read(),
      throwsA(isA<BankSessionRecoveryStorageException>()),
    );
  });
}
