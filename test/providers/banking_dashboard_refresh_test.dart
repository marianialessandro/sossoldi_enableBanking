import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/providers/transactions_provider.dart';
import 'package:sossoldi/services/banking/bank_authorization_context.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_provider.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_consent_lifecycle_service.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_result.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/bank_sync_harness.dart';

class _PendingStore implements PendingBankAuthorizationStore {
  PendingBankAuthorization? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<PendingBankAuthorization?> read() async => value;

  @override
  Future<void> save(PendingBankAuthorization pending) async => value = pending;
}

void main() {
  late BankSyncHarness harness;
  late BankConnectionRepository connections;
  late ProviderContainer container;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    harness = BankSyncHarness(databaseFactoryFfi);
    await harness.open();
    connections = BankConnectionRepository.withDatabase(harness.db);
    final provider = EnableBankingProvider(harness.api);
    final lifecycle = BankConsentLifecycleService(
      consent: provider.consent,
      institutions: provider.institutions,
      readContext: () async => const BankAuthorizationContext(
        providerId: 'enable_banking',
        applicationId: 'synthetic-app',
        redirectUri: 'sossoldi://eb-callback',
      ),
      pendingStore: _PendingStore(),
      connections: connections,
      clock: () => harness.localTime,
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(NativeContractDatabase(harness.db)),
        bankSyncServiceProvider.overrideWithValue(harness.service),
        bankConsentLifecycleServiceProvider.overrideWithValue(lifecycle),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await harness.close();
  });

  test(
    'bank sync updates an already visible dashboard without opening Transactions',
    () async {
      // Keep only the dashboard's recent list alive; the Transactions tab is never opened.
      container.listen(lastTransactionsProvider, (_, _) {});
      expect(await container.read(lastTransactionsProvider.future), isEmpty);

      final result = await container
          .read(connectBankFlowProvider.notifier)
          .syncConnectionId(1);

      expect(result.status, BankSyncStatus.success);
      final recent = await container.read(lastTransactionsProvider.future);
      expect(recent, hasLength(1));
      expect(recent.single.isBankImported, isTrue);
      expect(recent.single.note, 'Synthetic purchase');
      expect(await harness.total(), closeTo(232.75, 0.000001));
    },
  );

  for (final revokeRemotely in [true, false]) {
    test(
      '${revokeRemotely ? 'remote revocation' : 'local disconnect'} refreshes dashboard editing rules while preserving history',
      () async {
        expect(
          (await harness.service.syncAccount(1)).status,
          BankSyncStatus.success,
        );
        container.listen(lastTransactionsProvider, (_, _) {});
        final before = (await container.read(
          lastTransactionsProvider.future,
        )).single;
        expect(before.isBankImported, isTrue);
        final connection = await connections.selectById(1);
        final flow = container.read(connectBankFlowProvider.notifier);

        if (revokeRemotely) {
          await flow.disconnect(connection);
        } else {
          await flow.disconnectLocally(connection);
        }

        final recent = await container.read(lastTransactionsProvider.future);
        expect(recent, hasLength(1));
        expect(recent.single.id, before.id);
        expect(recent.single.isBankImported, isFalse);
        expect(recent.single.note, before.note);
        expect(recent.single.amount, before.amount);
        expect(await harness.total(), closeTo(232.75, 0.000001));
        expect(
          harness.requests.any((request) => request.method == 'DELETE'),
          revokeRemotely,
        );
      },
    );
  }
}
