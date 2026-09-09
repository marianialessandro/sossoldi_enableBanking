import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/services/banking/banking_backup_policy.dart';

void main() {
  test(
    'restored sync state retains exact money but cannot skip bank history',
    () {
      final restored = BankingBackupPolicy.sanitizeForRestore('bankSyncState', {
        'accountId': 1,
        'currency': 'EUR',
        'balanceMinor': '23275',
        'checkpoint': '2026-09-06',
        'completedAt': '2026-09-07T12:00:00Z',
      });
      expect(restored['checkpoint'], isNull);
      expect(restored['completedAt'], isNull);
      expect(restored['balanceMinor'], '23275');
    },
  );
  test('export redacts usable sessions and transient account identifiers', () {
    final connection =
        BankingBackupPolicy.sanitizeForExport(bankConnectionTable, {
          BankConnectionFields.sessionId: 'secret-session',
          BankConnectionFields.pendingSessionId: 'pending-session',
          BankConnectionFields.pendingAuthorizationId: 'authorization',
          BankConnectionFields.status: BankConnectionStatus.active.code,
        });
    final account = BankingBackupPolicy.sanitizeForExport(bankAccountTable, {
      BankAccountFields.ebAccountUid: 'session-account-uid',
      BankAccountFields.lastSyncAt: '2026-09-01T00:00:00.000Z',
      BankAccountFields.identificationHash: 'stable-hash',
    });

    expect(connection[BankConnectionFields.sessionId], isNull);
    expect(connection[BankConnectionFields.pendingSessionId], isNull);
    expect(connection[BankConnectionFields.pendingAuthorizationId], isNull);
    expect(
      connection[BankConnectionFields.status],
      BankConnectionStatus.reauthRequired.code,
    );
    expect(account[BankAccountFields.ebAccountUid], isNull);
    expect(account[BankAccountFields.lastSyncAt], isNull);
    expect(account[BankAccountFields.identificationHash], 'stable-hash');
  });

  test('restore never trusts active state or session values from a CSV', () {
    final restored =
        BankingBackupPolicy.sanitizeForRestore(bankConnectionTable, {
          BankConnectionFields.sessionId: 'attacker-session',
          BankConnectionFields.status: BankConnectionStatus.active.code,
        });

    expect(restored[BankConnectionFields.sessionId], isNull);
    expect(
      restored[BankConnectionFields.status],
      BankConnectionStatus.reauthRequired.code,
    );
  });
}
