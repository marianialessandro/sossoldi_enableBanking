import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';

import '../test/support/banking_recovery_actions_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      sharedPreferencesName: 'sossoldi_recovery_qa',
      preferencesKeyPrefix: 'recovery_qa_',
    ),
    iOptions: IOSOptions(
      accountName: 'sossoldi-recovery-qa',
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );
  for (final entry in recoveryActionCases(
    factory: databaseFactory,
    storage: storage,
  ).entries) {
    testWidgets(entry.key, entry.value);
  }
}
