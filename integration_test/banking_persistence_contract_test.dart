import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import '../test/support/banking_persistence_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  bankingPersistenceContract(
    databaseFactory,
    register: (name, body) {
      testWidgets(name, (tester) async {
        await tester.runAsync(body);
      });
    },
  );
}
