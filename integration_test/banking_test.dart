import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sossoldi/main.dart' as app;
import 'package:sossoldi/services/banking/enable_banking_config.dart';

// Throwaway key: parsable so setup accepts it, but not registered anywhere.
const _testPem = '''-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCSFvnfP7nAaqaF
v25mXIaHNRGN1sSp9MNC5Hb4uRi66nZcVPLR/Lcbpv+LhZSEEC/VC9gMb3UWBi7M
23c1HPuihvDGuQXBnOwzCD1l3vnZfC0rm6yY2ztZlfYZJL648UpuznizMbvaEAL5
Oxi343emTuSb+9HOzI/bgpDCvWQgu1GF1ZQIW/bmk18FrmL5MM8XMdbRxpLTaAXb
MESBXaTulHr84mXISjLX5afBAi47u3a7d3WFWDQ7Sun5WbsfKdIIMwruspnIn8dx
8JNd8JgoPu8flO8NJqFRzXaYKDFTTOQrFqyxVL0cmzUSGJYPb735E6nPAw7j3EM3
CoL+Y5dFAgMBAAECggEAI7NQsdFhY9fMRPAQmxwuVflOhmJ/IedqFj09o6+cDwWA
EjVCN7Wxy6SmW2Kz9gf8oGwqCnPsYYr2QeK6AXVJOyEN0wphETz3bcssMeppFVBm
u3rqFVqx6MUgZGmZ4Bk7LtPvJB9ZwELcbyqVck64rSAndsT1sztDRonkNWrR/rtZ
eDP/kzpz2cthHR1BwQ6YQ4k9Nj4hklz11pn9lDrGCA+ct5RdpiG2mlouQ6jNShRb
+LcOzog+Jxdi3bIMBqVpalKWQuBElAxCfJXMsW+NbjFEKpkWKVw0EwP+jnKHtG3+
sA2apVXISyBv/eH+jDQVPteYCPqhfmUgYlDs3UPIcQKBgQDFyYehb2IMpEVMjR1+
zm6S97Pdj2VL2ZN6mHRXO4dI+7nXMinzJHRsRRBa0zWurbnGUu8iHk4z15SkTDhn
dFj0snYnH/o7OYM49+x7qSA5Dw6Hn8maTyGTTfZ0bQdtH4rvREj0eaIaVjGhiP4H
CKaOa4es8EVpWRBdO/xQ7vLVjQKBgQC9Fj/2+UQ5z1tNAaCVCeWgn6HEW9yf7gh9
jY9ycbuxXVMaSDKW/y5HN0T1XkfiMGYedeUlw+iG6OsX+7YhkZXXPbaM+OMKb3sU
ltTcpdMVPvs309pP9rgO8lPm/ufLkE4G7mxtOikaX2WBoLaNfSQhZlr5JP+C4ygu
NSd67DVOmQKBgBkKN5KXkFk7Xs6fOvG33sXaeDn/knp01Df8HxaAIdN6kv+MiUUQ
A3FFmRl2jeBMfC2AiGfQYGQt0dKvF6D5WN25zj2Lzdk7ocJPmO/a7IpsvpErCJHx
nLWSdDYvK3aEPMmn4niZAY3GBciGmGp5jOSQ9n9Nd+wra2fyVTJF3hZtAoGAemMT
ZdTzbwOi0dYSzUTJp0yLlR/sTmvwfOuKhIXO+b8xEdrXO9rRZnEEpliu6F1xS5f9
iJMkR2Ys/KoEufeUZ+ve46IYumFr5ei2wFZoqODKE9mA/a7wdWQuIF6vQ5gUmPHr
pks13YcPmXafkjcEksXAbnCfHWXQVRA8jJik7EkCgYALMKFu62FJu1FzsaItaGxf
0HOd9uYF7N9D2hAWrbIHT4lJuRkOL0HAlt/28M9D91r8Y6mv8KP+G9l92fvotm/8
o8Rn5GSJg98Joy/8wvyo98/UI5zQsmk6BE4+IUeUc4FrjJlglNNH5z5PDa3+3csY
vcGIazwUx3uGDJYRHdsRhg==
-----END PRIVATE KEY-----''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> startApp(WidgetTester tester) async {
    // Skip onboarding: banking screens are reached from within the app.
    SharedPreferences.setMockInitialValues({'onboarding_completed': true});
    app.main();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  // Holds the screen long enough for `xcrun simctl io screenshot`: the
  // driver-side screenshot API isn't reliable on the iOS simulator.
  Future<void> shot(WidgetTester tester, String name) async {
    debugPrint('SHOT $name');
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 3)));
  }

  Future<void> openBankSync(WidgetTester tester) async {
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.settings));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Bank sync'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bank sync'));
    await tester.pumpAndSettle();

    expect(find.text('Configure Enable Banking'), findsOneWidget);
    expect(find.text('Connect banks'), findsOneWidget);

    await tester.tap(find.text('Configure Enable Banking'));
    await tester.pumpAndSettle();
  }

  Future<void> saveCredentials(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).at(0), _testPem);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'test-app-id');
    await tester.pumpAndSettle();
    await tester.tap(find.text('SAVE CREDENTIALS'));
    await tester.pumpAndSettle();
  }

  testWidgets('setup page rejects an invalid private key', (tester) async {
    await startApp(tester);
    await openBankSync(tester);

    expect(find.text('Enter your application ID'), findsOneWidget);
    expect(find.text(kEbRedirectUri), findsOneWidget);
    await shot(tester, '01_setup_empty');

    await tester.enterText(find.byType(TextField).at(0), 'not-a-real-key');
    await tester.enterText(find.byType(TextField).at(1), 'test-app-id');
    await tester.pumpAndSettle();
    await tester.tap(find.text('SAVE CREDENTIALS'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid private key'), findsOneWidget);
    await shot(tester, '02_invalid_key');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });

  testWidgets('credentials round trip through the iOS keychain', (
    tester,
  ) async {
    await startApp(tester);
    await openBankSync(tester);
    await saveCredentials(tester);

    expect(find.text('Credentials saved'), findsOneWidget);
    await shot(tester, '03_saved_dialog');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('Credentials configured'), findsOneWidget);
    expect(find.text('Linked banks'), findsOneWidget);
    expect(find.text('Clear credentials'), findsOneWidget);
    await shot(tester, '04_setup_configured');

    // Proves credentials survive in the keychain, not just in page state.
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Configure Enable Banking'));
    await tester.pumpAndSettle();

    expect(find.text('Credentials configured'), findsOneWidget);
    expect(find.text('test-app-id'), findsOneWidget);
    expect(find.text('•••• configured'), findsOneWidget);
  });

  testWidgets('connect bank page and country picker', (tester) async {
    await startApp(tester);
    await openBankSync(tester);

    await tester.tap(find.text('Linked banks'));
    await tester.pumpAndSettle();

    expect(find.text('Connect bank'), findsOneWidget);
    expect(find.text('No banks linked yet'), findsOneWidget);
    await shot(tester, '05_connect_bank_empty');

    await tester.tap(find.byIcon(Icons.add_circle));
    await tester.pumpAndSettle();

    expect(find.text('Country'), findsOneWidget);
    expect(find.text('Italy'), findsOneWidget);
    await shot(tester, '06_country_sheet');

    // Austria is the first row: no scrolling needed inside the sheet.
    await tester.tap(find.text('Austria'));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // No registered app: token is rejected; check failure shows, not a hang.
    expect(find.text('Bank'), findsOneWidget);
    await shot(tester, '07_aspsp_sheet');
  });

  testWidgets('clearing the credentials brings back the gate', (tester) async {
    await startApp(tester);
    await openBankSync(tester);

    await tester.scrollUntilVisible(
      find.text('Clear credentials'),
      200,
      // Multiple Scrollables (body, colour picker): name body explicitly.
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear credentials'));
    await tester.pumpAndSettle();

    expect(find.text('Clear credentials'), findsWidgets);
    await shot(tester, '08_clear_dialog');
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(find.text('Credentials cleared'), findsOneWidget);
    expect(find.text('Credentials configured'), findsNothing);
    expect(find.text('Linked banks'), findsNothing);
    await shot(tester, '09_cleared');
  });

  testWidgets('banking screens in dark mode', (tester) async {
    await startApp(tester);

    // The theme is an in-app preference, not the system appearance.
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('General Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.light_mode));
    await tester.pumpAndSettle();
    await shot(tester, '10_dark_general_settings');

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new).first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Bank sync'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bank sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Configure Enable Banking'));
    await tester.pumpAndSettle();
    await shot(tester, '11_dark_setup');

    await saveCredentials(tester);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await shot(tester, '12_dark_setup_configured');

    await tester.tap(find.text('Linked banks'));
    await tester.pumpAndSettle();
    await shot(tester, '13_dark_connect_bank');

    await tester.tap(find.byIcon(Icons.add_circle));
    await tester.pumpAndSettle();
    await shot(tester, '14_dark_country_sheet');
    await tester.tap(find.text('Austria'));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await shot(tester, '15_dark_aspsp_sheet');

    // No need to restore the theme: prefs are mocked and die with the test.
  });
}
