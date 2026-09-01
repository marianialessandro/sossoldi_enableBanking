import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/banking/enable_banking_config.dart';
import 'package:sossoldi/services/banking/enable_banking_exception.dart';
import 'package:sossoldi/services/banking/pending_bank_authorization_store.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'persists every cold-start callback field in encrypted storage',
    () async {
      const store = SecurePendingBankAuthorizationStore();
      final pending = PendingBankAuthorization(
        state: 'csrf-state',
        authorizationId: 'authorization-id',
        authorizationUrl: 'https://bank.example/authorize',
        applicationId: 'app-id',
        aspspName: 'Test Bank',
        aspspCountry: 'IT',
        redirectUri: kEbRedirectUri,
        expiresAt: DateTime.utc(2026, 9, 1, 12, 15),
        consentValidUntil: DateTime.utc(2026, 12, 1),
        reconnectConnectionId: 7,
      );

      await store.save(pending);
      final restored = await const SecurePendingBankAuthorizationStore().read();

      expect(restored?.state, 'csrf-state');
      expect(restored?.authorizationId, 'authorization-id');
      expect(restored?.aspspName, 'Test Bank');
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
          isA<EnableBankingException>().having(
            (error) => error.kind,
            'kind',
            EnableBankingFailureKind.invalidResponse,
          ),
        ),
      );
    },
  );
}
