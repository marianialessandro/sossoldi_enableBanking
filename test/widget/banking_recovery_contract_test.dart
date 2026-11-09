import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/banking_recovery_actions_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  for (final entry in recoveryActionCases(
    factory: databaseFactoryFfi,
    storage: const FlutterSecureStorage(),
  ).entries) {
    testWidgets(entry.key, entry.value);
  }
}
