import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';

import '../test/support/bank_sync_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  bankSyncContract(databaseFactory);
}
