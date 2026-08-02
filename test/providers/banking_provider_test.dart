import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/providers/banking_provider.dart';
import 'package:sossoldi/services/banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking_auth.dart';
import 'package:sossoldi/services/banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/enable_banking_deeplink_service.dart';
import 'package:sossoldi/services/banking/models/aspsp.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';

/// Bypasses credential/JWT signing entirely: the API client only needs a
/// valid bearer token string, not a real signature.
class _FakeAuth extends EnableBankingAuth {
  @override
  Future<String> getValidToken(EnableBankingCredentialsStore store) async =>
      'test-token';
}

/// In-memory stand-in for [BankConnectionRepository]: the `database` passed
/// to `super` is never touched because every method used by the flow is
/// overridden below.
class _FakeBankConnectionRepository extends BankConnectionRepository {
  _FakeBankConnectionRepository() : super(database: SossoldiDatabase());

  final List<BankConnection> connections = [];
  int _nextId = 1;

  @override
  Future<BankConnection> insert(BankConnection item) async {
    final saved = item.copy(id: _nextId++);
    connections.add(saved);
    return saved;
  }

  @override
  Future<List<BankConnection>> selectAll() async => List.of(connections);

  @override
  Future<int> markStatus(int id, BankConnectionStatus status) async {
    final index = connections.indexWhere((c) => c.id == id);
    if (index == -1) return 0;
    connections[index] = connections[index].copy(status: status);
    return 1;
  }
}

/// In-memory stand-in for [AccountRepository], same rationale as above.
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

/// Feeds deep links to [EnableBankingDeeplinkService] without going through
/// the `app_links` platform channel.
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
  late ProviderContainer container;

  ProviderContainer buildContainer(MockClientHandler handler) {
    connectionRepository = _FakeBankConnectionRepository();
    accountRepository = _FakeAccountRepository();
    linkSource = _FakeUriLinkSource();

    return ProviderContainer(
      overrides: [
        enableBankingApiProvider.overrideWithValue(
          EnableBankingApi(
            auth: _FakeAuth(),
            store: const EnableBankingCredentialsStore(),
            client: MockClient(handler),
          ),
        ),
        bankConnectionRepositoryProvider.overrideWithValue(
          connectionRepository,
        ),
        accountRepositoryProvider.overrideWithValue(accountRepository),
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
}
