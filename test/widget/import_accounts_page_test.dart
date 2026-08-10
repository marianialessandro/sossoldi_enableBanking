import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/pages/banking/import_accounts_page.dart';
import 'package:sossoldi/pages/banking/widgets/account_import_tile.dart';
import 'package:sossoldi/providers/banking_provider.dart';
import 'package:sossoldi/services/banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking_auth.dart';
import 'package:sossoldi/services/banking/enable_banking_config.dart';
import 'package:sossoldi/services/banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/models/aspsp.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sossoldi/ui/theme/app_theme.dart';

class _FakeAuth extends EnableBankingAuth {
  @override
  Future<String> getValidToken(EnableBankingCredentialsStore store) async =>
      'test-token';
}

/// Keeps [EnableBankingSettings] off the real secure storage platform
/// channel, which isn't mocked in this test.
class _FakeCredentialsStore extends EnableBankingCredentialsStore {
  const _FakeCredentialsStore();

  @override
  Future<EnableBankingConfig?> readConfig() async =>
      const EnableBankingConfig(appId: 'app-1');
}

class _FakeBankConnectionRepository extends BankConnectionRepository {
  _FakeBankConnectionRepository() : super(database: SossoldiDatabase());

  @override
  Future<BankConnection> insert(BankConnection item) async => item.copy(id: 1);

  @override
  Future<List<BankConnection>> selectAll() async => const [];
}

class _FakeAccountRepository extends AccountRepository {
  _FakeAccountRepository() : super(database: SossoldiDatabase());

  final List<BankAccount> accounts = [];
  bool failInsert = false;

  @override
  Future<BankAccount> insert(BankAccount item) async {
    if (failInsert) {
      throw Exception('database is locked');
    }
    final saved = item.copy(id: accounts.length + 1);
    accounts.add(saved);
    return saved;
  }

  @override
  Future<List<BankAccount>> selectAll({bool? active, bool? deleted}) async =>
      List.of(accounts);

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
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// [balanceGate], when given, delays the `/balances` response until it
/// completes — used to simulate the balance provider still being in
/// flight when the user taps import.
Future<http.Response> _handle(
  http.Request request, {
  Completer<void>? balanceGate,
}) async {
  final path = request.url.path;
  if (path == '/auth') {
    return _json({
      'url': 'https://bank.example/consent',
      'authorization_id': 'auth-1',
      'psu_id_hash': 'hash',
    });
  }
  if (path == '/sessions') {
    return _json({
      'session_id': 'session-1',
      'accounts': [
        {
          'uid': 'acc-1',
          'name': 'Checking',
          'currency': 'EUR',
          'account_id': {'iban': 'IT60X0542811101000000123456'},
        },
        {
          'uid': 'acc-2',
          'product': 'Savings',
          'currency': 'EUR',
          'account_id': {'iban': 'IT60X0542811101000000999999'},
        },
      ],
      'aspsp': {'name': 'Test Bank', 'country': 'IT'},
      'access': {'valid_until': '2026-12-01T00:00:00.000Z'},
      'psu_type': 'personal',
    });
  }
  if (path.endsWith('/balances')) {
    if (balanceGate != null) await balanceGate.future;
    return _json({
      'balances': [
        {
          'name': 'Booked',
          'balance_type': 'CLBD',
          'balance_amount': {'amount': '1234.50', 'currency': 'EUR'},
        },
      ],
    });
  }
  return http.Response('{}', 404);
}

void main() {
  late _FakeAccountRepository accountRepository;
  late ProviderContainer container;
  final navigatorKey = GlobalKey<NavigatorState>();

  /// Walks the flow up to the point the import page starts from: a consent
  /// completed, a session created and its accounts waiting to be imported.
  /// [balanceGate], when given, delays the balance fetch and skips the
  /// final `pumpAndSettle` (which would otherwise hang waiting for it), so
  /// the caller can interact with the page before the balance resolves.
  Future<void> pumpImportPage(
    WidgetTester tester, {
    Completer<void>? balanceGate,
  }) async {
    accountRepository = _FakeAccountRepository();
    container = ProviderContainer(
      overrides: [
        enableBankingApiProvider.overrideWithValue(
          EnableBankingApi(
            auth: _FakeAuth(),
            store: const EnableBankingCredentialsStore(),
            client: MockClient(
              (request) => _handle(request, balanceGate: balanceGate),
            ),
          ),
        ),
        enableBankingCredentialsStoreProvider.overrideWithValue(
          const _FakeCredentialsStore(),
        ),
        bankConnectionRepositoryProvider.overrideWithValue(
          _FakeBankConnectionRepository(),
        ),
        accountRepositoryProvider.overrideWithValue(accountRepository),
      ],
    );
    addTearDown(container.dispose);

    // The flow is autoDispose: hold a listener the way BankCallbackHandler
    // does in the app, otherwise the session is thrown away before the page
    // is built.
    final subscription = container.listen(connectBankFlowProvider, (_, _) {});
    addTearDown(subscription.close);

    final flow = container.read(connectBankFlowProvider.notifier);
    await flow.startConnection(const Aspsp(name: 'Test Bank', country: 'IT'));
    await flow.completeConnection(
      code: 'auth-code',
      returnedState: container.read(connectBankFlowProvider).csrfState!,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          navigatorKey: navigatorKey,
          initialRoute: '/connect-bank',
          onGenerateRoute: (settings) => MaterialPageRoute(
            settings: settings,
            builder: (_) => settings.name == '/import-accounts'
                ? const ImportAccountsPage()
                : const Scaffold(body: Text('connect bank page')),
          ),
        ),
      ),
    );
    navigatorKey.currentState!.pushNamed('/import-accounts');
    if (balanceGate != null) {
      await tester.pump();
      await tester.pump();
      return;
    }
    await tester.pumpAndSettle();
  }

  testWidgets('lists the accounts of the session with masked IBAN', (
    tester,
  ) async {
    await pumpImportPage(tester);

    expect(find.byType(AccountImportTile), findsNWidgets(2));
    expect(find.text('Checking'), findsWidgets);
    expect(find.text('Savings'), findsWidgets);
    expect(find.text('IT•• ••3456 · EUR'), findsOneWidget);
    expect(find.textContaining('Test Bank · 2 accounts'), findsOneWidget);
    expect(find.text('IMPORT SELECTED'), findsOneWidget);
  });

  testWidgets('shows the balance fetched for each account', (tester) async {
    await pumpImportPage(tester);

    expect(find.text('1234.50 EUR'), findsNWidgets(2));
  });

  testWidgets('imports only the selected accounts and goes back', (
    tester,
  ) async {
    await pumpImportPage(tester);

    // Drop the second account from the import (its tile is below the fold
    // because the first one is expanded).
    await tester.ensureVisible(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('IMPORT SELECTED'));
    await tester.pumpAndSettle();

    expect(accountRepository.accounts, hasLength(1));
    final imported = accountRepository.accounts.single;
    expect(imported.name, 'Checking');
    expect(imported.ebAccountUid, 'acc-1');
    expect(imported.ebConnectionId, 1);
    expect(imported.iban, 'IT60X0542811101000000123456');
    expect(imported.startingValue, 1234.50);
    expect(find.text('connect bank page'), findsOneWidget);
  });

  testWidgets('waits for the balance to resolve instead of importing with a 0 '
      'starting value', (tester) async {
    final balanceGate = Completer<void>();
    await pumpImportPage(tester, balanceGate: balanceGate);

    // Tapped while the /balances request is still pending: _import must
    // await it rather than reading whatever ebAccountBalanceProvider
    // happens to hold yet (nothing, at this point).
    await tester.tap(find.text('IMPORT SELECTED'));
    await tester.pump();

    expect(accountRepository.accounts, isEmpty);

    balanceGate.complete();
    await tester.pumpAndSettle();

    expect(accountRepository.accounts, hasLength(2));
    expect(
      accountRepository.accounts.map((a) => a.startingValue),
      everyElement(1234.50),
    );
  });

  testWidgets('disables the import button when nothing is selected', (
    tester,
  ) async {
    await pumpImportPage(tester);

    await tester.tap(find.byType(Switch).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();

    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'IMPORT SELECTED'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'resets the spinner and shows an error on a non-ConnectBankFlowException '
    'failure',
    (tester) async {
      await pumpImportPage(tester);
      accountRepository.failInsert = true;

      await tester.tap(find.text('IMPORT SELECTED'));
      await tester.pumpAndSettle();

      expect(find.text('Could not import the accounts'), findsOneWidget);
      expect(accountRepository.accounts, isEmpty);

      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'IMPORT SELECTED'),
      );
      expect(button.onPressed, isNotNull);
    },
  );

  testWidgets('keeps the name edited by the user', (tester) async {
    await pumpImportPage(tester);

    await tester.enterText(find.byType(TextField).first, 'My checking');
    await tester.ensureVisible(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('IMPORT SELECTED'));
    await tester.pumpAndSettle();

    expect(accountRepository.accounts.single.name, 'My checking');
  });
}
