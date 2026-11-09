import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/banking/enable_banking/models/eb_balance.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_data_mapper.dart';
import 'package:sossoldi/services/banking/banking_reference.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../support/bank_sync_harness.dart';

void main() {
  final acquired = DateTime.utc(2028, 2, 29, 12);
  final changed = DateTime.utc(2028, 1, 1);
  Map<String, dynamic> json() => {
    'name': 'Synthetic',
    'balance_amount': {'amount': '-10.00', 'currency': 'EUR'},
    'balance_type': 'ITBD',
    'reference_date': '2028-02-29',
    'last_change_date_time': changed.toIso8601String(),
    '_server_date': acquired.toIso8601String(),
  };
  group('BAL metadata', () {
    test('keeps acquisition, last change and civil reference distinct', () {
      final dto = EbBalance.fromJson(json());
      final value = const EnableBankingDataMapper().balance(dto);
      expect(dto.acquiredAt, acquired);
      expect(value.acquiredAt, acquired);
      expect(value.observedAt, changed);
      expect(value.referenceDate, DateTime.utc(2028, 2, 29));
      expect(value.amount.decimalAmount, '-10.00');
    });
    for (final invalid in [
      null,
      'invalid',
      42,
      '2028-02-30T12:00:00Z',
      '2028-02-29T12:00:00',
    ]) {
      test('invalid optional acquisition $invalid is absent', () {
        expect(
          EbBalance.fromJson({...json(), '_server_date': invalid}).acquiredAt,
          isNull,
        );
      });
    }
    test('bank calendar and timezone validation remains strict', () {
      expect(
        () => EbBalance.fromJson({...json(), 'reference_date': '2028-02-30'}),
        throwsFormatException,
      );
      expect(
        () => EbBalance.fromJson({
          ...json(),
          'last_change_date_time': '2028-02-29T12:00:00',
        }),
        throwsFormatException,
      );
    });
  });
  group('BAL transport', () {
    late BankSyncHarness h;
    setUpAll(sqfliteFfiInit);
    setUp(() async {
      h = BankSyncHarness(databaseFactoryFfi);
      await h.open();
    });
    tearDown(() => h.close());
    for (final date in ['Tue, 29 Feb 2028 12:00:00 GMT', '', 'bad']) {
      test('authoritative HTTP acquisition $date through adapter', () async {
        h.intercept = (request) async => h.response(
          {
            'balances': [json(), json()],
          },
          headers: {'date': date},
        );
        final balances = await EnableBankingProvider(h.api).accountData
            .getBalances(
              BankingAccountReference(
                providerId: 'enable_banking',
                remoteId: 'synthetic-uid-1',
              ),
            );
        expect(balances, hasLength(2));
        for (final value in balances) {
          expect(value.acquiredAt, date.startsWith('Tue') ? acquired : isNull);
          expect(value.observedAt, changed);
          expect(value.amount.decimalAmount, '-10.00');
        }
        expect(() => balances.clear(), throwsUnsupportedError);
      });
    }
  });
}
