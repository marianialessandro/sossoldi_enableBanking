import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_data_mapper.dart';
import 'package:sossoldi/services/banking/banking_balance.dart';
import 'package:sossoldi/services/banking/sync/bank_balance_selector.dart';
import 'package:sossoldi/services/banking/sync/bank_remote_transaction.dart';
import 'package:sossoldi/services/banking/enable_banking/models/eb_amount.dart';
import 'package:sossoldi/services/banking/enable_banking/models/eb_balance.dart';
import 'package:sossoldi/services/banking/enable_banking/models/eb_transaction.dart';

import '../../support/bank_sync_harness.dart';

void main() {
  final serverTime = DateTime.utc(2026, 9, 7, 12);
  final transactions = [
    BankRemoteTransaction.fromTransaction(
      const EnableBankingDataMapper().transaction(
        EbTransaction.fromJson(bankRecord()),
      ),
      'EUR',
    ),
  ];

  BankingBalance balance({
    String type = 'ITBD',
    String amount = '232.75',
    String currency = 'EUR',
    DateTime? at,
    DateTime? acquiredAt,
    String marker = 'ref-1',
  }) => const EnableBankingDataMapper().balance(
    EbBalance(
      name: 'Synthetic',
      balanceType: type,
      balanceAmount: EbAmount(
        amount: num.parse(amount),
        currency: currency,
        decimalAmount: amount,
      ),
      lastChangeDateTime: at ?? serverTime.subtract(const Duration(hours: 1)),
      acquiredAt: acquiredAt,
      lastCommittedTransaction: marker,
    ),
  );

  group('BAL selection', () {
    for (final seconds in [-1, 0, 1]) {
      test('legacy freshness threshold before at after $seconds', () {
        final at = serverTime
            .subtract(const Duration(days: 2))
            .subtract(Duration(seconds: seconds));
        expect(
          selectBankBalance([balance(at: at)], [], 'EUR', serverTime),
          isNull,
          reason:
              'Nonzero booked balance with empty history is never sufficient.',
        );
        final old = BankRemoteTransaction(
          key: 'ref:ref-1',
          entryReference: 'ref-1',
          transactionId: 'old',
          status: 'BOOK',
          date: DateTime.utc(2026, 9, 1),
          money: transactions.single.money,
          note: 'synthetic',
        );
        expect(
          selectBankBalance([balance(at: at)], [old], 'EUR', serverTime) !=
              null,
          seconds <= 0,
        );
      });
    }
    test('available nonfinal marker and empty nonzero stay conservative', () {
      expect(
        selectBankBalance(
          [balance(type: 'ITAV')],
          transactions,
          'EUR',
          serverTime,
        ),
        isNull,
      );
      final later = BankRemoteTransaction(
        key: 'ref:later',
        entryReference: 'later',
        transactionId: 'later',
        status: 'BOOK',
        date: DateTime.utc(2026, 9, 7),
        money: transactions.single.money,
        note: 'synthetic',
      );
      expect(
        selectBankBalance(
          [balance()],
          [...transactions, later],
          'EUR',
          serverTime,
        ),
        isNull,
      );
      expect(
        selectBankBalance(
          [balance(amount: '0.00', marker: '')],
          [],
          'EUR',
          serverTime,
        )?.money.minorUnits,
        BigInt.zero,
      );
      expect(
        selectBankBalance(
          [balance(amount: '-10.00', marker: '')],
          [],
          'EUR',
          serverTime,
        ),
        isNull,
      );
    });
    BankingBalance current({
      DateTime? acquired,
      DateTime? reference,
      DateTime? changed,
      String marker = 'ref-1',
      String amount = '-10.00',
    }) => BankingBalance(
      name: 'Synthetic',
      amount: balance(amount: amount).amount,
      kind: BankingBalanceKind.interimBooked,
      acquiredAt: acquired ?? serverTime,
      referenceDate: reference ?? DateTime.utc(2026, 9, 7),
      observedAt: changed,
      lastCommittedEntryId: marker,
    );
    test(
      'old unchanged amount has current civil reference and acquisition',
      () {
        final selected = selectBankBalance(
          [current(changed: DateTime.utc(2026, 8, 1))],
          transactions,
          'EUR',
          serverTime,
        );
        expect(selected?.money.minorUnits.toString(), '-1000');
        expect(selected?.at, serverTime);
      },
    );
    test('civil only uses real acquisition before midnight', () {
      expect(
        selectBankBalance([current()], transactions, 'EUR', serverTime)?.at,
        serverTime,
      );
    });
    test('boundary needs coherent read without assuming bank timezone', () {
      final at = DateTime.utc(2026, 9, 7, 23, 30);
      final value = current(acquired: at, reference: DateTime.utc(2026, 9, 8));
      expect(selectBankBalance([value], transactions, 'EUR', at), isNull);
      expect(
        selectBankBalance(
          [value],
          transactions,
          'EUR',
          at,
          coherentRead: true,
        )?.at,
        at,
      );
      expect(
        selectBankBalance(
          [current(acquired: at, reference: DateTime.utc(2026, 9, 9))],
          transactions,
          'EUR',
          at,
          coherentRead: true,
        ),
        isNull,
      );
    });
    test('fresh HTTP cannot rescue stale data or future last change', () {
      expect(
        selectBankBalance(
          [
            current(
              reference: DateTime.utc(2026, 8, 1),
              changed: DateTime.utc(2026, 8, 1),
            ),
          ],
          transactions,
          'EUR',
          serverTime,
        ),
        isNull,
      );
      expect(
        selectBankBalance(
          [current(changed: serverTime.add(const Duration(seconds: 1)))],
          transactions,
          'EUR',
          serverTime,
        ),
        isNull,
      );
      expect(selectBankBalance([current()], transactions, 'EUR', null), isNull);
      expect(
        selectBankBalance(
          [current(marker: 'absent')],
          transactions,
          'EUR',
          serverTime,
        ),
        isNull,
      );
    });
  });

  test('newer booked snapshot wins over an older closing balance', () {
    final selected = selectBankBalance(
      [
        balance(
          type: 'CLBD',
          amount: '305.89',
          at: DateTime.utc(2026, 9, 6, 23),
        ),
        balance(),
      ],
      transactions,
      'EUR',
      serverTime,
    );
    expect(selected?.money.decimal, '232.75');
  });
  test('same-time conflicting amounts are ambiguous', () {
    expect(
      selectBankBalance(
        [balance(), balance(amount: '300.00')],
        transactions,
        'EUR',
        serverTime,
      ),
      isNull,
    );
  });
  test(
    'CR01 common acquisition preserves demonstrated last-change precedence',
    () {
      final selected = selectBankBalance(
        [
          balance(
            type: 'CLBD',
            amount: '305.89',
            at: DateTime.utc(2026, 9, 6, 23),
            acquiredAt: serverTime,
          ),
          balance(acquiredAt: serverTime),
        ],
        transactions,
        'EUR',
        serverTime,
      );
      expect(selected?.money.decimal, '232.75');
      expect(selected?.at, serverTime);
      expect(
        selectBankBalance(
          [
            balance(
              type: 'ITBD',
              amount: '305.89',
              at: DateTime.utc(2026, 9, 6, 23),
              acquiredAt: serverTime,
            ),
            balance(type: 'CLBD', acquiredAt: serverTime),
          ],
          transactions,
          'EUR',
          serverTime,
        )?.money.decimal,
        '232.75',
        reason:
            'Precedence follows comparable dates, not an arbitrary balance-kind priority.',
      );
      expect(
        selectBankBalance(
          [
            balance(acquiredAt: serverTime),
            balance(amount: '300.00', acquiredAt: serverTime),
          ],
          transactions,
          'EUR',
          serverTime,
        ),
        isNull,
      );
    },
  );
  test(
    'currency mismatch, future timestamp and absent anchor cannot reconcile',
    () {
      expect(
        selectBankBalance(
          [balance(currency: 'USD')],
          transactions,
          'EUR',
          serverTime,
        ),
        isNull,
      );
      expect(
        selectBankBalance(
          [balance(at: serverTime.add(const Duration(seconds: 1)))],
          transactions,
          'EUR',
          serverTime,
        ),
        isNull,
      );
      expect(
        selectBankBalance(
          [balance(marker: 'unknown')],
          transactions,
          'EUR',
          serverTime,
        ),
        isNull,
      );
    },
  );
  test(
    'balance date parsing refuses malformed calendar dates and local timestamps',
    () {
      final base = <String, dynamic>{
        'name': 'Synthetic',
        'balance_amount': {'amount': '1.00', 'currency': 'EUR'},
        'balance_type': 'CLBD',
      };
      expect(
        () => EbBalance.fromJson({...base, 'reference_date': '2026-02-30'}),
        throwsFormatException,
      );
      expect(
        () => EbBalance.fromJson({
          ...base,
          'last_change_date_time': '2026-09-07T12:00:00',
        }),
        throwsFormatException,
      );
      expect(
        () => EbBalance.fromJson({
          ...base,
          'last_change_date_time': '2026-02-30T12:00:00Z',
        }),
        throwsFormatException,
      );
      expect(
        EbBalance.fromJson({
          ...base,
          'reference_date': '2026-09-07',
        }).referenceDate,
        DateTime.utc(2026, 9, 7),
      );
    },
  );
}
