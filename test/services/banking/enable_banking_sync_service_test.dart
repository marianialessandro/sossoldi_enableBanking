import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/services/banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking_auth.dart';
import 'package:sossoldi/services/banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/enable_banking_sync_service.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/repositories/transactions_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Bypasses JWT signing; the API client only needs a bearer token string
// (mirrors the fake in enable_banking_api_test.dart).
class _FakeAuth extends EnableBankingAuth {
  @override
  Future<String> getValidToken(EnableBankingCredentialsStore store) async =>
      'test-token';
}

// Simulates markStatus throwing on a 401 — the last path in syncConnection
// that can still throw up to syncAll's try/catch (others are isolated).
class _ThrowingMarkStatusRepository extends BankConnectionRepository {
  _ThrowingMarkStatusRepository({required super.database});

  @override
  Future<int> markStatus(int id, BankConnectionStatus status) async {
    throw StateError('database is locked');
  }
}

http.Response _json(Object body, {int statusCode = 200}) => http.Response(
  jsonEncode(body),
  statusCode,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _ebTransaction({
  required String status,
  required String creditDebitIndicator,
  required String amount,
  String? entryReference,
}) => {
  'status': status,
  'booking_date': '2026-01-05',
  'transaction_amount': {'amount': amount, 'currency': 'EUR'},
  'credit_debit_indicator': creditDebitIndicator,
  'entry_reference': ?entryReference,
};

void main() {
  late SossoldiDatabase sossoldiDatabase;
  late AccountRepository accountRepository;
  late TransactionsRepository transactionsRepository;
  late BankConnectionRepository bankConnectionRepository;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    sossoldiDatabase = SossoldiDatabase(dbName: 'test.db');
    await sossoldiDatabase.database;
  });

  setUp(() async {
    await sossoldiDatabase.clearDatabase();

    accountRepository = AccountRepository(database: sossoldiDatabase);
    transactionsRepository = TransactionsRepository(database: sossoldiDatabase);
    bankConnectionRepository = BankConnectionRepository(
      database: sossoldiDatabase,
    );
  });

  tearDown(() async => sossoldiDatabase.clearDatabase());

  tearDownAll(() => sossoldiDatabase.close());

  EnableBankingSyncService serviceWith(MockClientHandler handler) =>
      EnableBankingSyncService(
        api: EnableBankingApi(
          auth: _FakeAuth(),
          store: const EnableBankingCredentialsStore(),
          client: MockClient(handler),
        ),
        accountRepository: accountRepository,
        transactionsRepository: transactionsRepository,
        bankConnectionRepository: bankConnectionRepository,
      );

  group('EnableBankingSyncService.syncAccount', () {
    test('is a no-op for an account with no ebAccountUid', () async {
      final account = await accountRepository.insert(
        const BankAccount(
          name: 'Manual',
          symbol: 'wallet',
          color: 0,
          startingValue: 0,
          active: true,
          countNetWorth: true,
          mainAccount: false,
          order: 0,
        ),
      );

      final inserted = await serviceWith(
        (request) async => throw StateError('should not call the API'),
      ).syncAccount(account);

      expect(inserted, 0);
    });

    test('paginates via continuation_key, keeps only booked transactions, '
        'maps them and is idempotent on re-sync', () async {
      final account = await accountRepository.insert(
        const BankAccount(
          name: 'Revolut',
          symbol: 'payments',
          color: 1,
          startingValue: 0,
          active: true,
          countNetWorth: true,
          mainAccount: false,
          order: 0,
          ebAccountUid: 'acc-uid',
        ),
      );

      final service = serviceWith((request) async {
        final continuationKey = request.url.queryParameters['continuation_key'];
        if (continuationKey == null) {
          return _json({
            'transactions': [
              _ebTransaction(
                status: 'BOOK',
                creditDebitIndicator: 'CRDT',
                amount: '100.00',
                entryReference: 'entry-1',
              ),
              _ebTransaction(
                status: 'PDNG',
                creditDebitIndicator: 'DBIT',
                amount: '5.00',
                entryReference: 'entry-pending',
              ),
            ],
            'continuation_key': 'page-2',
          });
        }
        expect(continuationKey, 'page-2');
        return _json({
          'transactions': [
            _ebTransaction(
              status: 'BOOK',
              creditDebitIndicator: 'DBIT',
              amount: '30.00',
              entryReference: 'entry-2',
            ),
          ],
        });
      });

      final inserted = await service.syncAccount(account);
      expect(inserted, 2);

      final stored = await transactionsRepository.selectAll();
      expect(stored, hasLength(2));
      expect(stored.map((t) => t.externalId).toSet(), {'entry-1', 'entry-2'});

      final synced = await accountRepository.selectById(account.id!);
      expect(synced.lastSyncAt, isNotNull);

      final insertedAgain = await service.syncAccount(synced);
      expect(insertedAgain, 0);
      expect(await transactionsRepository.selectAll(), hasLength(2));
    });

    test(
      'rebases imported history to the authoritative booked balance',
      () async {
        final account = await accountRepository.insert(
          const BankAccount(
            name: 'Checking',
            symbol: 'payments',
            color: 1,
            startingValue: 372.38,
            active: true,
            countNetWorth: true,
            mainAccount: false,
            order: 0,
            ebAccountUid: 'acc-uid',
          ),
        );

        final service = serviceWith((request) async {
          if (request.url.path.endsWith('/balances')) {
            return _json({
              'balances': [
                {
                  'name': 'Closing booked',
                  'balance_amount': {'amount': '232.75', 'currency': 'EUR'},
                  'balance_type': 'CLBD',
                },
              ],
            });
          }
          return _json({
            'transactions': [
              _ebTransaction(
                status: 'BOOK',
                creditDebitIndicator: 'CRDT',
                amount: '100.00',
                entryReference: 'entry-in',
              ),
              _ebTransaction(
                status: 'BOOK',
                creditDebitIndicator: 'DBIT',
                amount: '166.49',
                entryReference: 'entry-out',
              ),
            ],
          });
        });

        await service.syncAccount(account);

        final reloaded = (await accountRepository.selectAll()).single;
        expect(reloaded.total, closeTo(232.75, 0.001));
        expect(reloaded.startingValue, closeTo(299.24, 0.001));
      },
    );

    test('is still idempotent on re-sync when the ASPSP sends neither '
        'entry_reference nor transaction_id (observed in production with at '
        'least one ASPSP)', () async {
      final account = await accountRepository.insert(
        const BankAccount(
          name: 'Banco BPM',
          symbol: 'payments',
          color: 1,
          startingValue: 0,
          active: true,
          countNetWorth: true,
          mainAccount: false,
          order: 0,
          ebAccountUid: 'acc-uid',
        ),
      );

      final service = serviceWith(
        (request) async => _json({
          'transactions': [
            _ebTransaction(
              status: 'BOOK',
              creditDebitIndicator: 'DBIT',
              amount: '9.90',
              // Missing both IDs — the gap that used to slip past dedup.
            ),
          ],
        }),
      );

      final inserted = await service.syncAccount(account);
      expect(inserted, 1);

      final synced = await accountRepository.selectById(account.id!);
      final insertedAgain = await service.syncAccount(synced);

      expect(insertedAgain, 0);
      expect(await transactionsRepository.selectAll(), hasLength(1));
    });
  });

  group('EnableBankingSyncService.syncConnection', () {
    test('marks the connection EXPIRED on a 401 and stops for it', () async {
      final connection = await bankConnectionRepository.insert(
        BankConnection(
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          sessionId: 'sess-1',
          validUntil: DateTime.now().add(const Duration(days: 90)),
          status: BankConnectionStatus.active,
        ),
      );
      await accountRepository.insert(
        BankAccount(
          name: 'Revolut',
          symbol: 'payments',
          color: 1,
          startingValue: 0,
          active: true,
          countNetWorth: true,
          mainAccount: false,
          order: 0,
          ebAccountUid: 'acc-uid',
          ebConnectionId: connection.id,
        ),
      );

      final service = serviceWith((request) async => http.Response('', 401));

      final synced = await service.syncConnection(connection);
      expect(synced, isEmpty);

      final reloaded = await bankConnectionRepository.selectById(
        connection.id!,
      );
      expect(reloaded.status, BankConnectionStatus.expired);
    });

    test('isolates non-401 API errors to the failing account and leaves the '
        'connection untouched', () async {
      final connection = await bankConnectionRepository.insert(
        BankConnection(
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          sessionId: 'sess-1',
          validUntil: DateTime.now().add(const Duration(days: 90)),
          status: BankConnectionStatus.active,
        ),
      );
      await accountRepository.insert(
        BankAccount(
          name: 'Revolut',
          symbol: 'payments',
          color: 1,
          startingValue: 0,
          active: true,
          countNetWorth: true,
          mainAccount: false,
          order: 0,
          ebAccountUid: 'acc-uid',
          ebConnectionId: connection.id,
        ),
      );

      final service = serviceWith((request) async => http.Response('', 500));

      final synced = await service.syncConnection(connection);
      expect(synced, isEmpty);

      final reloaded = await bankConnectionRepository.selectById(
        connection.id!,
      );
      expect(reloaded.status, BankConnectionStatus.active);
    });

    test('keeps syncing the other accounts of the same connection after one '
        'fails with a non-401 error', () async {
      final connection = await bankConnectionRepository.insert(
        BankConnection(
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          sessionId: 'sess-1',
          validUntil: DateTime.now().add(const Duration(days: 90)),
          status: BankConnectionStatus.active,
        ),
      );
      final good1 = await accountRepository.insert(
        BankAccount(
          name: 'Checking',
          symbol: 'payments',
          color: 1,
          startingValue: 0,
          active: true,
          countNetWorth: true,
          mainAccount: false,
          order: 0,
          ebAccountUid: 'acc-good-1',
          ebConnectionId: connection.id,
        ),
      );
      final bad = await accountRepository.insert(
        BankAccount(
          name: 'Broken',
          symbol: 'payments',
          color: 1,
          startingValue: 0,
          active: true,
          countNetWorth: true,
          mainAccount: false,
          order: 0,
          ebAccountUid: 'acc-bad',
          ebConnectionId: connection.id,
        ),
      );
      final good2 = await accountRepository.insert(
        BankAccount(
          name: 'Savings',
          symbol: 'payments',
          color: 1,
          startingValue: 0,
          active: true,
          countNetWorth: true,
          mainAccount: false,
          order: 0,
          ebAccountUid: 'acc-good-2',
          ebConnectionId: connection.id,
        ),
      );

      final service = serviceWith((request) async {
        if (request.url.path.contains('acc-bad')) {
          return http.Response('', 500);
        }
        return _json({'transactions': []});
      });

      final synced = await service.syncConnection(connection);

      expect(synced.containsKey(bad.id), isFalse);
      expect(synced[good1.id], 0);
      expect(synced[good2.id], 0);

      final reloaded = await bankConnectionRepository.selectById(
        connection.id!,
      );
      expect(reloaded.status, BankConnectionStatus.active);
    });
  });

  group('EnableBankingSyncService.syncAll', () {
    test('is a no-op when there are no active connections', () async {
      final service = serviceWith(
        (request) async => throw StateError('should not call the API'),
      );

      await service.syncAll();
    });

    test(
      'a connection whose sync throws all the way up to syncAll (e.g. '
      'markStatus failing on a 401) does not stop the others from syncing',
      () async {
        final failingConnection = await bankConnectionRepository.insert(
          BankConnection(
            aspspName: 'Failing Bank',
            aspspCountry: 'IT',
            sessionId: 'sess-1',
            validUntil: DateTime.now().add(const Duration(days: 90)),
            status: BankConnectionStatus.active,
          ),
        );
        await accountRepository.insert(
          BankAccount(
            name: 'Failing',
            symbol: 'payments',
            color: 1,
            startingValue: 0,
            active: true,
            countNetWorth: true,
            mainAccount: false,
            order: 0,
            ebAccountUid: 'acc-failing',
            ebConnectionId: failingConnection.id,
          ),
        );

        final goodConnection = await bankConnectionRepository.insert(
          BankConnection(
            aspspName: 'Good Bank',
            aspspCountry: 'IT',
            sessionId: 'sess-2',
            validUntil: DateTime.now().add(const Duration(days: 90)),
            status: BankConnectionStatus.active,
          ),
        );
        final goodAccount = await accountRepository.insert(
          BankAccount(
            name: 'Good',
            symbol: 'payments',
            color: 1,
            startingValue: 0,
            active: true,
            countNetWorth: true,
            mainAccount: false,
            order: 0,
            ebAccountUid: 'acc-good',
            ebConnectionId: goodConnection.id,
          ),
        );

        final service = EnableBankingSyncService(
          api: EnableBankingApi(
            auth: _FakeAuth(),
            store: const EnableBankingCredentialsStore(),
            client: MockClient((request) async {
              if (request.url.path.contains('acc-failing')) {
                return http.Response('', 401);
              }
              return _json({'transactions': []});
            }),
          ),
          accountRepository: accountRepository,
          transactionsRepository: transactionsRepository,
          bankConnectionRepository: _ThrowingMarkStatusRepository(
            database: sossoldiDatabase,
          ),
        );

        await service.syncAll();

        final reloadedGood = await accountRepository.selectById(
          goodAccount.id!,
        );
        expect(reloadedGood.lastSyncAt, isNotNull);
      },
    );
  });
}
