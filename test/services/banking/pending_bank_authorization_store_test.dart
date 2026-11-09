import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/banking/banking_exception.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_coordinator.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'conditional clear preserves a new owner auth or state with the same staged ID',
    () async {
      const store = SecurePendingBankAuthorizationStore();
      final now = DateTime.utc(2032);
      final original = PendingBankAuthorization(
        providerId: 'provider',
        state: 'state-A',
        authorizationId: 'auth-A',
        authorizationUrl: 'https://bank.example',
        applicationId: 'app-A',
        institutionName: 'Bank',
        institutionCountry: 'IT',
        redirectUri: 'sossoldi://eb-callback',
        expiresAt: now.add(const Duration(minutes: 15)),
        consentValidUntil: now.add(const Duration(days: 90)),
        stagedConnectionId: 7,
        phase: PendingAuthorizationPhase.connectionStaged,
      );
      for (final change in [
        {'provider_id': 'other'},
        {'application_id': 'app-B'},
        {'authorization_id': 'auth-B'},
        {'state': 'state-B'},
      ]) {
        final replacement = PendingBankAuthorization.fromJson({
          ...original.toJson(),
          ...change,
        });
        await store.save(replacement);
        expect(await store.clearIfCurrent(original), isFalse);
        expect((await store.read())!.toJson(), replacement.toJson());
      }
      await store.save(original);
      expect(await store.clearIfCurrent(original), isTrue);
      expect(await store.read(), isNull);
    },
  );

  test(
    'wrappers on one backend share a coordinator and independent backends do not',
    () {
      const backend = FlutterSecureStorage();
      const first = SecurePendingBankAuthorizationStore(storage: backend);
      const second = SecurePendingBankAuthorizationStore(storage: backend);
      const independent = SecurePendingBankAuthorizationStore(
        storage: FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        ),
      );
      expect(identical(first.coordinator, second.coordinator), isTrue);
      expect(identical(first.coordinator, independent.coordinator), isFalse);
    },
  );

  test(
    'cleanup survives Cancel and credential Clear, and removes only a confirmed owner',
    () async {
      const store = SecurePendingBankAuthorizationStore();
      const a = ObsoleteBankConnection(
        providerId: 'enable_banking',
        applicationId: 'A',
        authorizationId: 'auth-A',
        remoteConnectionId: 'session-A',
        attemptRevision: 1,
        reason: 'authorization_invalidated',
      );
      const b = ObsoleteBankConnection(
        providerId: 'enable_banking',
        applicationId: 'B',
        authorizationId: 'auth-B',
        remoteConnectionId: 'session-B',
        attemptRevision: 2,
        reason: 'authorization_invalidated',
      );
      await Future.wait([
        store.saveObsoleteConnection(a),
        store.saveObsoleteConnection(b),
        store.saveObsoleteConnection(a),
      ]);
      await store.clear();
      await const EnableBankingCredentialsStore().clear();
      final restored = await const SecurePendingBankAuthorizationStore()
          .readObsoleteConnections();
      expect(restored.map((value) => value.applicationId), ['A', 'B']);
      await store.removeObsoleteConnection(a);
      expect((await store.readObsoleteConnections()).single.applicationId, 'B');
    },
  );

  test(
    'legacy staged authorization keeps its storage keys and phase through a round trip',
    () async {
      final legacy = <String, Object?>{
        'version': 1,
        'state': 'legacy-state',
        'authorization_id': 'legacy-auth',
        'authorization_url': 'https://bank.example/authorize',
        'application_id': 'legacy-app',
        'aspsp_name': 'Legacy Bank',
        'aspsp_country': 'IT',
        'redirect_uri': 'sossoldi://eb-callback',
        'expires_at': '2026-09-12T10:15:00.000Z',
        'consent_valid_until': '2026-12-01T00:00:00.000Z',
        'reconnect_connection_id': 7,
        'staged_connection_id': 9,
        'phase': 'sessionStaged',
      };
      FlutterSecureStorage.setMockInitialValues({
        'eb_pending_authorization_v1': jsonEncode(legacy),
      });
      const store = SecurePendingBankAuthorizationStore();
      final restored = (await store.read())!;
      expect(restored.providerId, 'enable_banking');
      expect(restored.institutionName, 'Legacy Bank');
      expect(restored.institutionCountry, 'IT');
      expect(restored.phase, PendingAuthorizationPhase.connectionStaged);
      expect(restored.stagedConnectionId, 9);
      await store.save(restored);
      final encoded =
          jsonDecode(
                (await const FlutterSecureStorage().read(
                  key: 'eb_pending_authorization_v1',
                ))!,
              )
              as Map<String, dynamic>;
      expect(encoded, {...legacy, 'provider_id': 'enable_banking'});
      expect(
        (await store.read())!.phase,
        PendingAuthorizationPhase.connectionStaged,
      );
    },
  );

  test(
    'persists every cold-start callback field in encrypted storage',
    () async {
      const store = SecurePendingBankAuthorizationStore();
      final pending = PendingBankAuthorization(
        providerId: 'alternative',
        state: 'csrf-state',
        authorizationId: 'authorization-id',
        authorizationUrl: 'https://bank.example/authorize',
        applicationId: 'app-id',
        institutionName: 'Test Bank',
        institutionCountry: 'IT',
        redirectUri: 'sossoldi://eb-callback',
        expiresAt: DateTime.utc(2026, 9, 1, 12, 15),
        consentValidUntil: DateTime.utc(2026, 12, 1),
        reconnectConnectionId: 7,
      );

      await store.save(pending);
      final restored = await const SecurePendingBankAuthorizationStore().read();

      expect(restored?.providerId, 'alternative');
      expect(
        PendingBankAuthorization.fromJson(
          pending.toJson()..remove('provider_id'),
        ).providerId,
        'enable_banking',
      );
      expect(restored?.state, 'csrf-state');
      expect(restored?.authorizationId, 'authorization-id');
      expect(restored?.institutionName, 'Test Bank');
      expect(restored?.reconnectConnectionId, 7);
      expect(restored?.expiresAt, DateTime.utc(2026, 9, 1, 12, 15));
    },
  );

  test(
    'corrupted pending state is rejected instead of partially read',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'eb_pending_authorization_v1': '{bad json',
      });

      await expectLater(
        () => const SecurePendingBankAuthorizationStore().read(),
        throwsA(
          isA<BankingException>().having(
            (error) => error.failure,
            'kind',
            BankingFailure.invalidResponse,
          ),
        ),
      );
    },
  );
}
