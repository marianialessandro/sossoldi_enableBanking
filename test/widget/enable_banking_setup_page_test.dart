import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/pages/settings/banking/enable_banking_setup_page.dart';
import 'package:sossoldi/providers/banking_provider.dart';
import 'package:sossoldi/services/banking/enable_banking_auth.dart';
import 'package:sossoldi/services/banking/enable_banking_config.dart';
import 'package:sossoldi/services/banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/ui/theme/app_theme.dart';

/// In-memory stand-in for the secure storage backed store: every method the
/// page uses is overridden, so the platform channel is never touched.
class _FakeCredentialsStore extends EnableBankingCredentialsStore {
  String? appId;
  String? privateKeyPem;
  EnableBankingConfig? config;

  @override
  Future<void> saveCredentials({
    required String appId,
    required String privateKeyPem,
    required EnableBankingConfig config,
  }) async {
    this.appId = appId;
    this.privateKeyPem = privateKeyPem;
    this.config = config;
  }

  @override
  Future<EnableBankingConfig?> readConfig() async => config;

  @override
  Future<String?> readPrivateKey() async => privateKeyPem;

  @override
  Future<bool> hasCredentials() async => appId != null && privateKeyPem != null;

  @override
  Future<void> clear() async {
    appId = null;
    privateKeyPem = null;
    config = null;
  }
}

/// Skips the real RS256 signing: the page only uses it to validate the PEM.
class _FakeAuth extends EnableBankingAuth {
  _FakeAuth({this.keyIsValid = true});

  final bool keyIsValid;

  @override
  String buildJwt({
    required String appId,
    required String privateKeyPem,
    Duration ttl = const Duration(hours: 1),
  }) {
    if (!keyIsValid) {
      throw const EnableBankingAuthException('Invalid private key');
    }
    return 'test-token';
  }
}

void main() {
  late _FakeCredentialsStore store;

  Future<void> pumpPage(WidgetTester tester, {bool keyIsValid = true}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          enableBankingCredentialsStoreProvider.overrideWithValue(store),
          enableBankingAuthProvider.overrideWithValue(
            _FakeAuth(keyIsValid: keyIsValid),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const EnableBankingSetupPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => store = _FakeCredentialsStore());

  testWidgets('renders the form and hides the configured-only bits', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('Bank sync'), findsOneWidget);
    expect(find.text('APPLICATION ID'), findsOneWidget);
    expect(find.text('PRIVATE KEY (PEM)'), findsOneWidget);
    expect(find.text('ENVIRONMENT'), findsOneWidget);
    expect(find.text('REDIRECT URI'), findsOneWidget);
    expect(find.text('sossoldi://eb-callback'), findsOneWidget);
    expect(find.text('SAVE CREDENTIALS'), findsOneWidget);

    expect(find.text('Credentials configured'), findsNothing);
    expect(find.text('Clear credentials'), findsNothing);
  });

  testWidgets('saves the credentials entered by the user', (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField).at(0), 'app-123');
    await tester.enterText(find.byType(TextField).at(1), 'PEM-CONTENT');
    await tester.tap(find.text('SAVE CREDENTIALS'));
    await tester.pumpAndSettle();

    expect(store.appId, 'app-123');
    expect(store.privateKeyPem, 'PEM-CONTENT');
    expect(store.config?.environment, EnableBankingEnvironment.production);
    expect(find.text('Credentials saved'), findsOneWidget);
  });

  testWidgets('stores the sandbox environment when the switch is on', (
    tester,
  ) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField).at(0), 'app-123');
    await tester.enterText(find.byType(TextField).at(1), 'PEM-CONTENT');
    // The environment card sits below the fold on the test viewport.
    await tester.ensureVisible(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SAVE CREDENTIALS'));
    await tester.pumpAndSettle();

    expect(store.config?.environment, EnableBankingEnvironment.sandbox);
  });

  testWidgets('refuses to save without an application id', (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField).at(1), 'PEM-CONTENT');
    await tester.tap(find.text('SAVE CREDENTIALS'));
    await tester.pumpAndSettle();

    expect(store.appId, isNull);
    expect(
      find.text('Enter your Enable Banking application ID'),
      findsOneWidget,
    );
  });

  testWidgets('refuses to save an unparsable private key', (tester) async {
    await pumpPage(tester, keyIsValid: false);

    await tester.enterText(find.byType(TextField).at(0), 'app-123');
    await tester.enterText(find.byType(TextField).at(1), 'not-a-key');
    await tester.tap(find.text('SAVE CREDENTIALS'));
    await tester.pumpAndSettle();

    expect(store.appId, isNull);
    expect(find.text('Invalid private key'), findsOneWidget);
  });

  group('with credentials already saved', () {
    setUp(() {
      store
        ..appId = 'saved-app'
        ..privateKeyPem = 'SAVED-PEM'
        ..config = const EnableBankingConfig(
          appId: 'saved-app',
          environment: EnableBankingEnvironment.sandbox,
        );
    });

    testWidgets('prefills the id, the environment and the saved state', (
      tester,
    ) async {
      await pumpPage(tester);

      expect(find.text('saved-app'), findsOneWidget);
      expect(find.text('Credentials configured'), findsOneWidget);
      expect(find.text('Clear credentials'), findsOneWidget);
      // The key is never read back into the form.
      expect(find.text('SAVED-PEM'), findsNothing);
      expect(find.text('•••• configured'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('keeps the stored key when the field is left empty', (
      tester,
    ) async {
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField).at(0), 'new-app');
      await tester.tap(find.text('SAVE CREDENTIALS'));
      await tester.pumpAndSettle();

      expect(store.appId, 'new-app');
      expect(store.privateKeyPem, 'SAVED-PEM');
    });

    testWidgets('clears everything after the confirmation dialog', (
      tester,
    ) async {
      await pumpPage(tester);

      await tester.ensureVisible(find.text('Clear credentials'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear credentials'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(store.appId, isNull);
      expect(store.privateKeyPem, isNull);
      expect(find.text('Credentials cleared'), findsOneWidget);
      expect(find.text('Credentials configured'), findsNothing);
    });
  });
}
