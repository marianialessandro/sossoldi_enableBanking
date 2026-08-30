import 'dart:async';

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_account.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/pages/banking/connect_bank_page.dart';
import 'package:sossoldi/pages/banking/widgets/connection_card.dart';
import 'package:sossoldi/providers/banking_provider.dart';
import 'package:sossoldi/services/banking/enable_banking_config.dart';
import 'package:sossoldi/services/banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/enable_banking_deeplink_service.dart';
import 'package:sossoldi/services/database/repositories/account_repository.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sossoldi/ui/theme/app_theme.dart';

class _FakeCredentialsStore extends EnableBankingCredentialsStore {
  _FakeCredentialsStore({this.config});

  final EnableBankingConfig? config;

  @override
  Future<EnableBankingConfig?> readConfig() async => config;

  @override
  Future<bool> hasCredentials() async => config != null;
}

class _FakeBankConnectionRepository extends BankConnectionRepository {
  _FakeBankConnectionRepository(this.connections)
    : super(database: SossoldiDatabase());

  final List<BankConnection> connections;

  @override
  Future<List<BankConnection>> selectAll() async => connections;
}

class _FakeAccountRepository extends AccountRepository {
  _FakeAccountRepository(this.accounts) : super(database: SossoldiDatabase());

  final List<BankAccount> accounts;

  @override
  Future<List<BankAccount>> selectAll({bool? active, bool? deleted}) async =>
      accounts;
}

class _SilentUriLinkSource implements UriLinkSource {
  final StreamController<Uri> controller = StreamController<Uri>.broadcast();

  @override
  Stream<Uri> get uriStream => controller.stream;

  @override
  Future<Uri?> getInitialUri() async => null;
}

BankAccount _linkedAccount({required int connectionId}) => BankAccount(
  id: 1,
  name: 'Checking',
  symbol: 'payments',
  color: 0,
  startingValue: 0,
  active: true,
  countNetWorth: true,
  mainAccount: false,
  order: 0,
  ebAccountUid: 'acc-1',
  ebConnectionId: connectionId,
);

void main() {
  late _SilentUriLinkSource linkSource;

  Future<void> pumpPage(
    WidgetTester tester, {
    EnableBankingConfig? config,
    List<BankConnection> connections = const [],
    List<BankAccount> accounts = const [],
  }) async {
    linkSource = _SilentUriLinkSource();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          enableBankingCredentialsStoreProvider.overrideWithValue(
            _FakeCredentialsStore(config: config),
          ),
          bankConnectionRepositoryProvider.overrideWithValue(
            _FakeBankConnectionRepository(connections),
          ),
          accountRepositoryProvider.overrideWithValue(
            _FakeAccountRepository(accounts),
          ),
          enableBankingDeeplinkServiceProvider.overrideWithValue(
            EnableBankingDeeplinkService(source: linkSource),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const ConnectBankPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() => linkSource.controller.close());

  testWidgets('without credentials it asks to configure them first', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(
      find.text('Configure your Enable Banking credentials first'),
      findsOneWidget,
    );
    expect(find.text('CONFIGURE'), findsOneWidget);
    expect(find.text('No banks linked yet'), findsNothing);

    final addButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.add_circle),
    );
    expect(addButton.onPressed, isNull);
  });

  testWidgets('with credentials and no connection it shows the empty state', (
    tester,
  ) async {
    await pumpPage(tester, config: const EnableBankingConfig(appId: 'app-1'));

    expect(find.text('No banks linked yet'), findsOneWidget);
    expect(find.text('CONFIGURE'), findsNothing);

    final addButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.add_circle),
    );
    expect(addButton.onPressed, isNotNull);
  });

  testWidgets('country picker renders image flags', (tester) async {
    await pumpPage(tester, config: const EnableBankingConfig(appId: 'app-1'));

    await tester.tap(find.widgetWithIcon(IconButton, Icons.add_circle));
    await tester.pumpAndSettle();

    expect(find.byType(CountryFlag), findsWidgets);
    expect(find.text('Italy'), findsOneWidget);
    expect(find.text('IT'), findsOneWidget);
  });

  testWidgets('lists an active connection with its linked accounts', (
    tester,
  ) async {
    await pumpPage(
      tester,
      config: const EnableBankingConfig(appId: 'app-1'),
      connections: [
        BankConnection(
          id: 7,
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          sessionId: 'session-1',
          validUntil: DateTime.now().add(const Duration(days: 30)),
          status: BankConnectionStatus.active,
        ),
      ],
      accounts: [_linkedAccount(connectionId: 7)],
    );

    expect(find.byType(ConnectionCard), findsOneWidget);
    expect(find.text('Test Bank'), findsOneWidget);
    expect(find.textContaining('1 accounts · valid until'), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('Last synced never'), findsOneWidget);
    expect(find.text('RECONNECT'), findsNothing);
  });

  testWidgets('offers to reconnect when the consent is expired', (
    tester,
  ) async {
    await pumpPage(
      tester,
      config: const EnableBankingConfig(appId: 'app-1'),
      connections: [
        BankConnection(
          id: 8,
          aspspName: 'Old Bank',
          aspspCountry: 'IT',
          sessionId: 'session-2',
          validUntil: DateTime.now().subtract(const Duration(days: 1)),
          status: BankConnectionStatus.active,
        ),
      ],
    );

    expect(find.text('EXPIRED'), findsOneWidget);
    expect(find.text('RECONNECT'), findsOneWidget);
    expect(find.widgetWithIcon(IconButton, Icons.link_off), findsNothing);
  });

  testWidgets('asks to confirm before disconnecting', (tester) async {
    await pumpPage(
      tester,
      config: const EnableBankingConfig(appId: 'app-1'),
      connections: [
        BankConnection(
          id: 9,
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          sessionId: 'session-3',
          validUntil: DateTime.now().add(const Duration(days: 30)),
          status: BankConnectionStatus.active,
        ),
      ],
    );

    await tester.tap(find.widgetWithIcon(IconButton, Icons.link_off));
    await tester.pumpAndSettle();

    expect(find.text('Disconnect bank'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });
}
