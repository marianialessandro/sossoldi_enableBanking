import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/pages/settings/banking/enable_banking_setup_page.dart';
import 'package:sossoldi/providers/banking_provider.dart';
import 'package:sossoldi/services/banking/enable_banking_auth.dart';
import 'package:sossoldi/services/banking/enable_banking_config.dart';
import 'package:sossoldi/services/banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/enable_banking_key_generator.dart';
import 'package:sossoldi/ui/theme/app_theme.dart';

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
  Future<void> savePrivateKey(String privateKeyPem) async {
    this.privateKeyPem = privateKeyPem;
  }

  @override
  Future<bool> hasCredentials() async => appId != null && privateKeyPem != null;

  @override
  Future<void> clear() async {
    appId = null;
    privateKeyPem = null;
    config = null;
  }

  @override
  Future<void> clearConfig() async {
    appId = null;
    config = null;
  }
}

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

class _FakeKeyGenerator extends EnableBankingKeyGenerator {
  const _FakeKeyGenerator();

  @override
  Future<EnableBankingKeyMaterial> generate({
    int keySize = kEnableBankingKeySize,
  }) async => const EnableBankingKeyMaterial(
    privateKeyPem: 'GENERATED-PEM',
    certificatePem: 'GENERATED-CERT',
  );
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
          enableBankingKeyGeneratorProvider.overrideWithValue(
            const _FakeKeyGenerator(),
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
    expect(find.text('Register your application'), findsOneWidget);
    expect(find.text('Generate your key'), findsOneWidget);
    expect(find.text('Enter your application ID'), findsOneWidget);
    expect(find.text('Register the redirect URI'), findsOneWidget);
    expect(find.text('Choose your environment'), findsOneWidget);
    expect(find.text(kEbRedirectUri), findsOneWidget);
    expect(find.text('SAVE CREDENTIALS'), findsOneWidget);

    expect(find.text('Credentials configured'), findsNothing);
    expect(find.text('Clear credentials'), findsNothing);
    expect(find.text('Import from file'), findsNothing);
    expect(find.byIcon(Icons.upload_file), findsNothing);
  });

  testWidgets('saves the application id with the stored key', (tester) async {
    store.privateKeyPem = 'STORED-PEM';
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField).at(0), 'app-123');
    await tester.tap(find.text('SAVE CREDENTIALS'));
    await tester.pumpAndSettle();

    expect(store.appId, 'app-123');
    expect(store.privateKeyPem, 'STORED-PEM');
    expect(store.config?.environment, EnableBankingEnvironment.production);
    expect(find.text('Credentials saved'), findsOneWidget);
  });

  testWidgets('stores the sandbox environment when the switch is on', (
    tester,
  ) async {
    store.privateKeyPem = 'STORED-PEM';
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField).at(0), 'app-123');
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

    await tester.tap(find.text('SAVE CREDENTIALS'));
    await tester.pumpAndSettle();

    expect(store.appId, isNull);
    expect(
      find.text('Enter your Enable Banking application ID'),
      findsOneWidget,
    );
  });

  testWidgets('asks to generate a key before saving', (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField).at(0), 'app-123');
    await tester.tap(find.text('SAVE CREDENTIALS'));
    await tester.pumpAndSettle();

    expect(store.appId, isNull);
    expect(find.text('Generate a key and certificate first'), findsOneWidget);
  });

  testWidgets('refuses to save an unparsable private key', (tester) async {
    store.privateKeyPem = 'INVALID-STORED-PEM';
    await pumpPage(tester, keyIsValid: false);

    await tester.enterText(find.byType(TextField).at(0), 'app-123');
    await tester.tap(find.text('SAVE CREDENTIALS'));
    await tester.pumpAndSettle();

    expect(store.appId, isNull);
    expect(find.text('Invalid private key'), findsOneWidget);
  });

  group('generating a key in-app', () {
    testWidgets(
      'stores the key and shows certificate actions without opening it',
      (tester) async {
        await pumpPage(tester);

        await tester.ensureVisible(find.text('Generate new key & certificate'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Generate new key & certificate'));
        await tester.pumpAndSettle();

        expect(store.privateKeyPem, 'GENERATED-PEM');
        expect(
          find.text(
            'Key generated — upload the certificate from step 2, then enter '
            'your app_id in step 3 below',
          ),
          findsOneWidget,
        );
        expect(find.text('Certificate ready'), findsOneWidget);
        expect(find.text('Copy certificate'), findsOneWidget);
        expect(find.text('View certificate'), findsOneWidget);
        expect(find.text('GENERATED-CERT'), findsNothing);
      },
    );

    testWidgets('opens the generated certificate only when requested', (
      tester,
    ) async {
      await pumpPage(tester);

      await tester.ensureVisible(find.text('Generate new key & certificate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate new key & certificate'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('View certificate'));
      await tester.tap(find.text('View certificate'));
      await tester.pumpAndSettle();

      expect(find.text('GENERATED-CERT'), findsOneWidget);
      expect(find.text('Save to file'), findsOneWidget);
    });

    testWidgets('copies the generated certificate from the ready panel', (
      tester,
    ) async {
      String? copiedText;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await pumpPage(tester);

      await tester.ensureVisible(find.text('Generate new key & certificate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate new key & certificate'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Copy certificate'));
      await tester.tap(find.text('Copy certificate'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Certificate copied'), findsOneWidget);
      expect(copiedText, 'GENERATED-CERT');
    });

    testWidgets('asks for confirmation before replacing an existing key', (
      tester,
    ) async {
      store.privateKeyPem = 'EXISTING-PEM';
      await pumpPage(tester);

      await tester.ensureVisible(find.text('Generate new key & certificate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate new key & certificate'));
      await tester.pumpAndSettle();

      expect(find.text('Generate a new key?'), findsOneWidget);
      expect(store.privateKeyPem, 'EXISTING-PEM');

      await tester.tap(find.text('Generate'));
      await tester.pumpAndSettle();

      expect(store.privateKeyPem, 'GENERATED-PEM');
    });

    testWidgets('cancelling the confirmation keeps the existing key', (
      tester,
    ) async {
      store.privateKeyPem = 'EXISTING-PEM';
      await pumpPage(tester);

      await tester.ensureVisible(find.text('Generate new key & certificate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Generate new key & certificate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(store.privateKeyPem, 'EXISTING-PEM');
    });
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
      expect(find.text('SAVED-PEM'), findsNothing);
      expect(find.text('Import from file'), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('keeps the stored key when changing the application id', (
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

    testWidgets(
      'regenerating the key clears the old config but keeps the new key '
      'readable',
      (tester) async {
        await pumpPage(tester);

        await tester.ensureVisible(find.text('Generate new key & certificate'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Generate new key & certificate'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Generate'));
        await tester.pumpAndSettle();

        expect(store.appId, isNull);
        expect(store.config, isNull);
        // New key must survive the old app_id/config being cleared.
        expect(store.privateKeyPem, 'GENERATED-PEM');
      },
    );
  });
}
