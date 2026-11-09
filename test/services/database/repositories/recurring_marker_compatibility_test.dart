import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sossoldi/services/database/repositories/recurring_transactions_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';

class _CountingRepository extends RecurringTransactionRepository {
  _CountingRepository() : super(database: SossoldiDatabase());
  int checks = 0;

  @override
  Future<void> checkRecurringTransactions() async {
    checks++;
  }
}

void main() {
  const key = 'last_recurring_transactions_check';
  for (final invalid in <Object>[
    '',
    'not-a-date',
    true,
    42,
    <String>['bad'],
  ]) {
    test(
      'legacy API recovers invalid preference marker $invalid before startup continues',
      () async {
        SharedPreferences.setMockInitialValues({key: invalid});
        final prefs = await SharedPreferences.getInstance();
        final repository = _CountingRepository();
        await repository.dailyCheck(prefs);
        expect(repository.checks, 1);
        final saved = prefs.get(key);
        expect(saved, isA<String>());
        expect(DateTime.tryParse(saved! as String), isNotNull);
      },
    );
  }
}
