import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/pages/banking/widgets/bank_sync_context_dialog.dart';

void main() {
  testWidgets(
    'import copy and readable labels focus the first invalid field and reject line breaks',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BankSyncContextDialog(
              headers: ['Psu-Ip-Address', 'Psu-User-Agent'],
              importing: true,
            ),
          ),
        ),
      );
      expect(find.text('Your IP address'), findsOneWidget);
      expect(find.text('Browser or app details'), findsOneWidget);
      expect(find.textContaining('to load your accounts'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      final first = tester.widget<TextFormField>(
        find.byType(TextFormField).first,
      );
      expect(
        tester
            .widget<TextField>(find.byType(TextField).first)
            .focusNode!
            .hasFocus,
        isTrue,
      );
      first.controller!.text = '192.0.2.1\r\n';
      await tester.enterText(
        find.byType(TextFormField).last,
        'Synthetic client',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a value for this request'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byType(TextField).first)
            .focusNode!
            .hasFocus,
        isTrue,
      );
    },
  );
  testWidgets(
    'interactive context validates all required values and returns them once',
    (tester) async {
      Map<String, String>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<Map<String, String>>(
                    context: context,
                    builder: (_) => const BankSyncContextDialog(
                      headers: ['Psu-Ip-Address', 'Psu-User-Agent'],
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a value for this request'), findsNWidgets(2));
      await tester.enterText(find.byType(TextFormField).first, 'invalid');
      await tester.enterText(
        find.byType(TextFormField).last,
        'Synthetic client',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid IP address'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '192.0.2.1');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(result, {
        'Psu-Ip-Address': '192.0.2.1',
        'Psu-User-Agent': 'Synthetic client',
      });
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        isEmpty,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );
}
