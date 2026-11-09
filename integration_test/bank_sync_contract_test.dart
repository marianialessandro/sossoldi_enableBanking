import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';

import '../test/support/bank_sync_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  bankSyncContract(
    databaseFactory,
    register: (name, body) {
      testWidgets(name, (tester) async {
        await tester.runAsync(body);
      });
    },
  );
}
