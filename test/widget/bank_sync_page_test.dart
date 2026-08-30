import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/pages/settings/banking/bank_sync_page.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const BankSyncPage(),
        routes: {
          '/enable-banking-setup': (_) =>
              const Scaffold(body: Text('Enable Banking setup destination')),
          '/connect-bank': (_) =>
              const Scaffold(body: Text('Connect banks destination')),
        },
      ),
    );
  }

  testWidgets('shows both Bank sync options and opens their pages', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('Configure Enable Banking'), findsOneWidget);
    expect(find.text('Connect banks'), findsOneWidget);

    await tester.tap(find.text('Configure Enable Banking'));
    await tester.pumpAndSettle();
    expect(find.text('Enable Banking setup destination'), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect banks'));
    await tester.pumpAndSettle();
    expect(find.text('Connect banks destination'), findsOneWidget);
  });
}
