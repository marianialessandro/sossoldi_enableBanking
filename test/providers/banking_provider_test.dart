import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/model/transaction.dart';
import 'package:sossoldi/providers/banking_provider.dart';
import 'package:sossoldi/providers/settings_provider.dart';
import 'package:sossoldi/services/banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking_auth.dart';
import 'package:sossoldi/services/banking/enable_banking_config.dart';
import 'package:sossoldi/services/banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/enable_banking_deeplink_service.dart';
import 'package:sossoldi/services/banking/models/aspsp.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/repositories/transactions_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';

// Bypasses JWT signing: the client only needs a bearer token string.
class _FakeAuth extends EnableBankingAuth {
  @override
  Future<String> getValidToken(EnableBankingCredentialsStore store) async =>
      'test-token';
}

// Simulates credentials vanishing mid-OAuth: first call succeeds, rest fail.
class _ThrowingAuth extends EnableBankingAuth {
  int calls = 0;

  @override
  Future<String> getValidToken(EnableBankingCredentialsStore store) async {
    calls++;
    if (calls == 1) return 'test-token';
    throw const EnableBankingAuthException('Credentials are not valid');
  }
}

// Keeps credentials off secure storage; unavailable in tests.
class _FakeCredentialsStore extends EnableBankingCredentialsStore {
  _FakeCredentialsStore({this.config});

  final EnableBankingConfig? config;

  @override
  Future<EnableBankingConfig?> readConfig() async => config;

  @override
  Future<bool> hasCredentials() async => config != null;
}

// In-memory BankConnectionRepository; overridden methods avoid the real
// database.
class _FakeBankConnectionRepository extends BankConnectionRepository {
  _FakeBankConnectionRepository({required this.accountRepository})
    : super(database: SossoldiDatabase());

  final _FakeAccountRepository accountRepository;
  final List<BankConnection> connections = [];
  int _nextId = 1;
  int selectAllCalls = 0;

  @override
  Future<BankConnection> insert(BankConnection item) async {
    final saved = item.copy(id: _nextId++);
    connections.add(saved);
    return saved;
  }

  @override
  Future<List<BankConnection>> selectAll() async {
    selectAllCalls++;
    return List.of(connections);
  }

  @override
  Future<List<BankConnection>> selectActive() async => connections
      .where((c) => c.status == BankConnectionStatus.active)
      .toList();

  @override
  Future<int> markStatus(int id, BankConnectionStatus status) async {
    final index = connections.indexWhere((c) => c.id == id);
    if (index == -1) return 0;
    connections[index] = connections[index].copy(status: status);
    return 1;
  }

  @override
  Future<int> updateItem(BankConnection item) async {
    final index = connections.indexWhere((c) => c.id == item.id);
    if (index == -1) return 0;
    connections[index] = item;
    return 1;
  }

  @override
  Future<void> finalizeDisconnect(int connectionId) async {
    for (final account in accountRepository.accounts) {
      if (account.ebConnectionId == connectionId) {
        await accountRepository.unlink(account.id!);
      }
    }
    await markStatus(connectionId, BankConnectionStatus.revoked);
  }
}

// In-memory stand-in for AccountRepository, same rationale as above.
class _FakeAccountRepository extends AccountRepository {
  _FakeAccountRepository() : super(database: SossoldiDatabase());

  final List<BankAccount> accounts = [];
  int _nextId = 1;

  @override
  Future<BankAccount> insert(BankAccount item) async {
    final saved = item.copy(id: _nextId++);
    accounts.add(saved);
    return saved;
  }

  @override
  Future<List<BankAccount>> selectLinked() async =>
      accounts.where((a) => a.ebAccountUid != null).toList();

  @override
  Future<BankAccount?> selectByEbUid(String uid) async {
    for (final account in accounts) {
      if (account.ebAccountUid == uid) return account;
    }
    return null;
  }

  @override
  Future<int> updateItem(BankAccount item) async {
    final index = accounts.indexWhere((a) => a.id == item.id);
    if (index == -1) return 0;
    accounts[index] = item;
    return 1;
  }

  @override
  Future<void> updateLastSync(int accountId, DateTime when) async {}

  @override
  Future<void> unlink(int accountId) async {
    final index = accounts.indexWhere((a) => a.id == accountId);
    if (index == -1) return;
    final current = accounts[index];
    accounts[index] = BankAccount(
      id: current.id,
      name: current.name,
      symbol: current.symbol,
      color: current.color,
      startingValue: current.startingValue,
      active: current.active,
      countNetWorth: current.countNetWorth,
      mainAccount: current.mainAccount,
      order: current.order,
    );
  }
}

// In-memory TransactionsRepository; importAccounts now syncs on connect.
class _FakeTransactionsRepository extends TransactionsRepository {
  _FakeTransactionsRepository() : super(database: SossoldiDatabase());

  @override
  Future<int> insertMissing(List<Transaction> items) async => items.length;
}

// Feeds deep links to EnableBankingDeeplinkService without `app_links`.
class _FakeUriLinkSource implements UriLinkSource {
  final StreamController<Uri> controller = StreamController<Uri>.broadcast();

  @override
  Stream<Uri> get uriStream => controller.stream;

  @override
  Future<Uri?> getInitialUri() async => null;
}

http.Response _json(Object body, {int statusCode = 200}) => http.Response(
  jsonEncode(body),
  statusCode,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _sessionJson({
  String sessionId = 'session-1',
  String aspspName = 'Test Bank',
  String aspspCountry = 'IT',
}) => {
  'session_id': sessionId,
  'accounts': [
    {
      'uid': 'acc-1',
      'name': 'Checking',
      'account_id': {'iban': 'IT60X0542811101000000123456'},
    },
  ],
  'aspsp': {'name': aspspName, 'country': aspspCountry},
  'access': {'valid_until': '2026-12-01T00:00:00.000Z'},
  'psu_type': 'personal',
};

void main() {
  late _FakeBankConnectionRepository connectionRepository;
  late _FakeAccountRepository accountRepository;
  late _FakeUriLinkSource linkSource;
  late SharedPreferences sharedPreferences;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
  });

  // Nullable with a non-null default so bankAutoSyncProvider's "no
  // credentials" case can pass an explicit `null` to the fake store.
  ProviderContainer buildContainer(
    MockClientHandler handler, {
    EnableBankingConfig? config = const EnableBankingConfig(appId: 'app-1'),
    EnableBankingAuth? auth,
  }) {
    accountRepository = _FakeAccountRepository();
    connectionRepository = _FakeBankConnectionRepository(
      accountRepository: accountRepository,
    );
    linkSource = _FakeUriLinkSource();

    return ProviderContainer(
      overrides: [
        sharedPrefProvider.overrideWithValue(sharedPreferences),
        enableBankingApiProvider.overrideWithValue(
          EnableBankingApi(
            auth: auth ?? _FakeAuth(),
            store: const EnableBankingCredentialsStore(),
            client: MockClient(handler),
          ),
        ),
        enableBankingCredentialsStoreProvider.overrideWithValue(
          _FakeCredentialsStore(config: config),
        ),
        bankConnectionRepositoryProvider.overrideWithValue(
          connectionRepository,
        ),
        accountRepositoryProvider.overrideWithValue(accountRepository),
        transactionsRepositoryProvider.overrideWithValue(
          _FakeTransactionsRepository(),
        ),
        enableBankingDeeplinkServiceProvider.overrideWithValue(
          EnableBankingDeeplinkService(source: linkSource),
        ),
      ],
    );
  }

  tearDown(() {
    container.dispose();
    linkSource.controller.close();
  });

  group('ConnectBankFlow', () {
    test(
      'startConnection stores a csrfState and returns the consent url',
      () async {
        container = buildContainer((request) async {
          expect(request.url.path, '/auth');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['state'], isNotEmpty);
          return _json({
            'url': 'https://bank.example/consent',
            'authorization_id': 'auth-1',
            'psu_id_hash': 'hash',
          });
        });

        final notifier = container.read(connectBankFlowProvider.notifier);
        const aspsp = Aspsp(name: 'Test Bank', country: 'IT');

        final url = await notifier.startConnection(aspsp);

        expect(url, 'https://bank.example/consent');
        final state = container.read(connectBankFlowProvider);
        expect(state.csrfState, isNotEmpty);
        expect(state.authorizing, isFalse);
      },
    );

    test(
      'startConnection sends the redirect_uri configured by the user',
      () async {
        late http.Request captured;
        container = buildContainer(
          (request) async {
            captured = request;
            return _json({
              'url': 'https://bank.example/consent',
              'authorization_id': 'auth-1',
              'psu_id_hash': 'hash',
            });
          },
          config: const EnableBankingConfig(
            appId: 'app-1',
            redirectUri: 'https://example.com/sossoldi/eb-callback.html',
          ),
        );

        final notifier = container.read(connectBankFlowProvider.notifier);
        const aspsp = Aspsp(name: 'Test Bank', country: 'IT');

        await notifier.startConnection(aspsp);

        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(
          body['redirect_url'],
          'https://example.com/sossoldi/eb-callback.html',
        );
      },
    );

    test(
      'completeConnection with the matching state persists the session',
      () async {
        container = buildContainer((request) async {
          if (request.url.path == '/auth') {
            return _json({
              'url': 'https://bank.example/consent',
              'authorization_id': 'auth-1',
              'psu_id_hash': 'hash',
            });
          }
          expect(request.url.path, '/sessions');
          expect(jsonDecode(request.body), {'code': 'auth-code'});
          return _json(_sessionJson());
        });

        final notifier = container.read(connectBankFlowProvider.notifier);
        const aspsp = Aspsp(name: 'Test Bank', country: 'IT');
        await notifier.startConnection(aspsp);
        final csrfState = container.read(connectBankFlowProvider).csrfState!;

        await notifier.completeConnection(
          code: 'auth-code',
          returnedState: csrfState,
        );

        final state = container.read(connectBankFlowProvider);
        expect(state.session?.sessionId, 'session-1');
        expect(state.importable, hasLength(1));
        expect(state.connectionId, isNotNull);

        expect(connectionRepository.connections, hasLength(1));
        expect(connectionRepository.connections.single.sessionId, 'session-1');
        expect(
          connectionRepository.connections.single.status,
          BankConnectionStatus.active,
        );
      },
    );

    test(
      'completeConnection with a mismatched state throws and persists nothing',
      () async {
        container = buildContainer((request) async {
          if (request.url.path == '/auth') {
            return _json({
              'url': 'https://bank.example/consent',
              'authorization_id': 'auth-1',
              'psu_id_hash': 'hash',
            });
          }
          fail('must not call /sessions when the CSRF state is invalid');
        });

        final notifier = container.read(connectBankFlowProvider.notifier);
        const aspsp = Aspsp(name: 'Test Bank', country: 'IT');
        await notifier.startConnection(aspsp);

        await expectLater(
          notifier.completeConnection(
            code: 'auth-code',
            returnedState: 'not-the-csrf-state',
          ),
          throwsA(isA<ConnectBankFlowException>()),
        );

        expect(connectionRepository.connections, isEmpty);
      },
    );

    test('startConnection with reconnecting updates the existing connection '
        'instead of inserting a duplicate', () async {
      container = buildContainer((request) async {
        if (request.url.path == '/auth') {
          return _json({
            'url': 'https://bank.example/consent',
            'authorization_id': 'auth-1',
            'psu_id_hash': 'hash',
          });
        }
        expect(request.url.path, '/sessions');
        return _json(_sessionJson(sessionId: 'session-2'));
      });

      final existing = await connectionRepository.insert(
        BankConnection(
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          sessionId: 'session-1',
          validUntil: DateTime.now().subtract(const Duration(days: 1)),
          status: BankConnectionStatus.expired,
        ),
      );

      final notifier = container.read(connectBankFlowProvider.notifier);
      const aspsp = Aspsp(name: 'Test Bank', country: 'IT');
      await notifier.startConnection(aspsp, reconnecting: existing);
      final csrfState = container.read(connectBankFlowProvider).csrfState!;

      await notifier.completeConnection(
        code: 'auth-code',
        returnedState: csrfState,
      );

      expect(connectionRepository.connections, hasLength(1));
      final updated = connectionRepository.connections.single;
      expect(updated.id, existing.id);
      expect(updated.sessionId, 'session-2');
      expect(updated.status, BankConnectionStatus.active);
      expect(container.read(connectBankFlowProvider).connectionId, existing.id);
    });

    test('a fresh (non-reconnect) startConnection clears a stale reconnecting '
        'value from a previous attempt', () async {
      container = buildContainer((request) async {
        if (request.url.path == '/auth') {
          return _json({
            'url': 'https://bank.example/consent',
            'authorization_id': 'auth-1',
            'psu_id_hash': 'hash',
          });
        }
        expect(request.url.path, '/sessions');
        return _json(_sessionJson(sessionId: 'session-2'));
      });

      final existing = await connectionRepository.insert(
        BankConnection(
          aspspName: 'Old Bank',
          aspspCountry: 'IT',
          sessionId: 'session-1',
          validUntil: DateTime.now().subtract(const Duration(days: 1)),
          status: BankConnectionStatus.expired,
        ),
      );

      final notifier = container.read(connectBankFlowProvider.notifier);
      await notifier.startConnection(
        const Aspsp(name: 'Old Bank', country: 'IT'),
        reconnecting: existing,
      );
      // A fresh flow afterwards must not keep reconnecting into the old one.
      await notifier.startConnection(
        const Aspsp(name: 'New Bank', country: 'IT'),
      );
      final csrfState = container.read(connectBankFlowProvider).csrfState!;

      await notifier.completeConnection(
        code: 'auth-code',
        returnedState: csrfState,
      );

      expect(connectionRepository.connections, hasLength(2));
      final inserted = connectionRepository.connections.firstWhere(
        (c) => c.id != existing.id,
      );
      expect(inserted.sessionId, 'session-2');
    });

    test(
      'importAccounts persists selected accounts linked to the connection',
      () async {
        container = buildContainer((request) async {
          if (request.url.path == '/auth') {
            return _json({
              'url': 'https://bank.example/consent',
              'authorization_id': 'auth-1',
              'psu_id_hash': 'hash',
            });
          }
          return _json(_sessionJson());
        });

        final notifier = container.read(connectBankFlowProvider.notifier);
        const aspsp = Aspsp(name: 'Test Bank', country: 'IT');
        await notifier.startConnection(aspsp);
        final csrfState = container.read(connectBankFlowProvider).csrfState!;
        await notifier.completeConnection(
          code: 'auth-code',
          returnedState: csrfState,
        );

        final ebAccount = container
            .read(connectBankFlowProvider)
            .importable
            .single;
        await notifier.importAccounts([
          BankAccountImportSelection(
            account: ebAccount,
            name: 'My checking',
            symbol: 'payments',
            color: 0,
            startingValue: 1000,
          ),
        ]);

        expect(accountRepository.accounts, hasLength(1));
        final imported = accountRepository.accounts.single;
        expect(imported.name, 'My checking');
        expect(imported.ebAccountUid, ebAccount.uid);
        expect(
          imported.ebConnectionId,
          connectionRepository.connections.single.id,
        );
        expect(imported.iban, ebAccount.iban);
        expect(container.read(connectBankFlowProvider).importable, isEmpty);
      },
    );

    test('importAccounts without a completed connection throws', () async {
      container = buildContainer((_) async => fail('no request expected'));
      final notifier = container.read(connectBankFlowProvider.notifier);

      await expectLater(
        notifier.importAccounts(const []),
        throwsA(isA<ConnectBankFlowException>()),
      );
    });

    test('disconnect revokes the session and unlinks its accounts', () async {
      container = buildContainer((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/sessions/session-1');
        return http.Response('', 204);
      });

      final connection = await connectionRepository.insert(
        BankConnection(
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          sessionId: 'session-1',
          validUntil: DateTime.utc(2026, 12),
          status: BankConnectionStatus.active,
        ),
      );
      final linkedAccount = await accountRepository.insert(
        BankAccount(
          name: 'Checking',
          symbol: 'payments',
          color: 0,
          startingValue: 0,
          active: true,
          countNetWorth: true,
          mainAccount: false,
          order: 0,
          ebAccountUid: 'acc-1',
          ebConnectionId: connection.id,
        ),
      );

      final notifier = container.read(connectBankFlowProvider.notifier);
      await notifier.disconnect(connection);

      expect(
        connectionRepository.connections.single.status,
        BankConnectionStatus.revoked,
      );
      final unlinked = accountRepository.accounts.firstWhere(
        (a) => a.id == linkedAccount.id,
      );
      expect(unlinked.ebAccountUid, isNull);
      expect(unlinked.ebConnectionId, isNull);

      // A revoked connection must not linger in "Linked banks".
      expect(await container.read(bankConnectionsProvider.future), isEmpty);
    });
  });

  group('BankCallbackHandler', () {
    Map<String, dynamic> authJson() => {
      'url': 'https://bank.example/consent',
      'authorization_id': 'auth-1',
      'psu_id_hash': 'hash',
    };

    Future<String> startFlow() async {
      // Reading the handler starts the deep link listener.
      container.read(bankCallbackHandlerProvider);
      await container
          .read(connectBankFlowProvider.notifier)
          .startConnection(const Aspsp(name: 'Test Bank', country: 'IT'));
      return container.read(connectBankFlowProvider).csrfState!;
    }

    test('a callback deep link completes the connection', () async {
      container = buildContainer((request) async {
        if (request.url.path == '/auth') return _json(authJson());
        expect(request.url.path, '/sessions');
        expect(jsonDecode(request.body), {'code': 'auth-code'});
        return _json(_sessionJson());
      });

      final csrfState = await startFlow();
      linkSource.controller.add(
        Uri.parse('sossoldi://eb-callback?code=auth-code&state=$csrfState'),
      );
      await pumpEventQueue();

      final state = container.read(bankCallbackHandlerProvider);
      expect(state.errorMessage, isNull);
      expect(state.processing, isFalse);
      expect(state.connectionId, connectionRepository.connections.single.id);
    });

    test('a refused authorization reports the error', () async {
      container = buildContainer((request) async {
        if (request.url.path == '/auth') return _json(authJson());
        fail('must not call /sessions when the user refused consent');
      });

      await startFlow();
      linkSource.controller.add(
        Uri.parse(
          'sossoldi://eb-callback?error=access_denied'
          '&error_description=User+refused',
        ),
      );
      await pumpEventQueue();

      expect(
        container.read(bankCallbackHandlerProvider).errorMessage,
        'User refused',
      );
      expect(connectionRepository.connections, isEmpty);
    });

    test('an EnableBankingAuthException while completing the connection '
        'resets processing and reports the error, instead of leaving the UI '
        'stuck', () async {
      container = buildContainer((request) async {
        if (request.url.path == '/auth') return _json(authJson());
        fail('must not call /sessions once credentials are invalid');
      }, auth: _ThrowingAuth());

      final csrfState = await startFlow();
      linkSource.controller.add(
        Uri.parse('sossoldi://eb-callback?code=auth-code&state=$csrfState'),
      );
      await pumpEventQueue();

      final state = container.read(bankCallbackHandlerProvider);
      expect(state.processing, isFalse);
      expect(state.errorMessage, 'Credentials are not valid');
      expect(connectionRepository.connections, isEmpty);
    });

    test('a callback with a mismatched state creates no session', () async {
      container = buildContainer((request) async {
        if (request.url.path == '/auth') return _json(authJson());
        fail('must not call /sessions when the CSRF state is invalid');
      });

      await startFlow();
      linkSource.controller.add(
        Uri.parse('sossoldi://eb-callback?code=auth-code&state=forged'),
      );
      await pumpEventQueue();

      expect(
        container.read(bankCallbackHandlerProvider).errorMessage,
        isNotNull,
      );
      expect(connectionRepository.connections, isEmpty);
    });

    test('a callback without a flow in progress is reported', () async {
      container = buildContainer((_) async => fail('no request expected'));

      container.read(bankCallbackHandlerProvider);
      linkSource.controller.add(
        Uri.parse('sossoldi://eb-callback?code=auth-code&state=csrf'),
      );
      await pumpEventQueue();

      expect(
        container.read(bankCallbackHandlerProvider).errorMessage,
        'No bank connection in progress, please start again',
      );
      expect(connectionRepository.connections, isEmpty);
    });
  });

  group('bankAutoSyncProvider', () {
    test(
      'invalidates bankConnectionsProvider after syncing, so the '
      'already-built UI refetches instead of showing pre-sync data',
      () async {
        container = buildContainer(
          (request) async => fail('no request expected'),
          config: const EnableBankingConfig(appId: 'app-1'),
        );
        connectionRepository.connections.add(
          BankConnection(
            aspspName: 'Test Bank',
            aspspCountry: 'IT',
            sessionId: 'sess-1',
            validUntil: DateTime.now().add(const Duration(days: 90)),
            status: BankConnectionStatus.active,
          ),
        );

        // Warm the provider the way the already-built UI would have.
        await container.read(bankConnectionsProvider.future);
        expect(connectionRepository.selectAllCalls, 1);

        await container.read(bankAutoSyncProvider.future);

        // A fresh read must force a new selectAll(), not the stale value.
        await container.read(bankConnectionsProvider.future);
        expect(connectionRepository.selectAllCalls, 2);

        expect(
          sharedPreferences.getString('last_bank_sync_check_v2'),
          isNotNull,
        );
      },
    );

    test('is a no-op without Enable Banking credentials', () async {
      container = buildContainer(
        (request) async => fail('no request expected'),
        config: null,
      );
      connectionRepository.connections.add(
        BankConnection(
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          sessionId: 'sess-1',
          validUntil: DateTime.now().add(const Duration(days: 90)),
          status: BankConnectionStatus.active,
        ),
      );

      await container.read(bankConnectionsProvider.future);
      expect(connectionRepository.selectAllCalls, 1);

      await container.read(bankAutoSyncProvider.future);

      expect(sharedPreferences.getString('last_bank_sync_check_v2'), isNull);
      // No invalidation happened: still cached, no new selectAll() call.
      await container.read(bankConnectionsProvider.future);
      expect(connectionRepository.selectAllCalls, 1);
    });

    test('does not run again the same day', () async {
      await sharedPreferences.setString(
        'last_bank_sync_check_v2',
        DateTime.now().toIso8601String(),
      );
      container = buildContainer(
        (request) async => fail('no request expected'),
        config: const EnableBankingConfig(appId: 'app-1'),
      );
      connectionRepository.connections.add(
        BankConnection(
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          sessionId: 'sess-1',
          validUntil: DateTime.now().add(const Duration(days: 90)),
          status: BankConnectionStatus.active,
        ),
      );

      await container.read(bankConnectionsProvider.future);
      expect(connectionRepository.selectAllCalls, 1);

      await container.read(bankAutoSyncProvider.future);

      await container.read(bankConnectionsProvider.future);
      expect(connectionRepository.selectAllCalls, 1);
    });
  });
}
