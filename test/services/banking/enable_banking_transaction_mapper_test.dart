import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/transaction.dart';
import 'package:sossoldi/services/banking/enable_banking_transaction_mapper.dart';
import 'package:sossoldi/services/banking/models/eb_amount.dart';
import 'package:sossoldi/services/banking/models/eb_transaction.dart';

EbTransaction _tx({
  String status = 'BOOK',
  DateTime? bookingDate,
  DateTime? valueDate,
  DateTime? transactionDate,
  num amount = 10,
  String currency = 'EUR',
  String creditDebitIndicator = 'CRDT',
  String? creditorName,
  String? debtorName,
  List<String> remittanceInformation = const [],
  String? note,
  String? entryReference,
  String? transactionId,
}) => EbTransaction(
  status: status,
  bookingDate: bookingDate,
  valueDate: valueDate,
  transactionDate: transactionDate,
  transactionAmount: EbAmount(amount: amount, currency: currency),
  creditDebitIndicator: creditDebitIndicator,
  creditorName: creditorName,
  debtorName: debtorName,
  remittanceInformation: remittanceInformation,
  note: note,
  entryReference: entryReference,
  transactionId: transactionId,
);

void main() {
  group('mapEbTransaction', () {
    test('maps a credit to a positive-amount income transaction', () {
      final transaction = mapEbTransaction(
        _tx(creditDebitIndicator: 'CRDT', amount: 42.5),
        idBankAccount: 7,
      );

      expect(transaction.amount, 42.5);
      expect(transaction.type, TransactionType.income);
      expect(transaction.idBankAccount, 7);
    });

    test('maps a debit to a positive-amount expense transaction', () {
      final transaction = mapEbTransaction(
        _tx(creditDebitIndicator: 'DBIT', amount: 42.5),
        idBankAccount: 7,
      );

      expect(transaction.amount, 42.5);
      expect(transaction.type, TransactionType.expense);
    });

    test('treats any non-CRDT indicator (e.g. DBDT) as an expense', () {
      final transaction = mapEbTransaction(
        _tx(creditDebitIndicator: 'DBDT', amount: 5),
        idBankAccount: 7,
      );

      expect(transaction.type, TransactionType.expense);
      expect(transaction.amount, 5);
    });

    test('prefers bookingDate, then transactionDate, then valueDate', () {
      final bookingDate = DateTime.utc(2026, 1, 3);
      final transactionDate = DateTime.utc(2026, 1, 2);
      final valueDate = DateTime.utc(2026, 1, 1);

      expect(
        mapEbTransaction(
          _tx(
            bookingDate: bookingDate,
            transactionDate: transactionDate,
            valueDate: valueDate,
          ),
          idBankAccount: 1,
        ).date,
        bookingDate,
      );
      expect(
        mapEbTransaction(
          _tx(transactionDate: transactionDate, valueDate: valueDate),
          idBankAccount: 1,
        ).date,
        transactionDate,
      );
      expect(
        mapEbTransaction(_tx(valueDate: valueDate), idBankAccount: 1).date,
        valueDate,
      );
    });

    test('falls back to now when no date is available', () {
      final before = DateTime.now();
      final transaction = mapEbTransaction(_tx(), idBankAccount: 1);
      final after = DateTime.now();

      expect(
        transaction.date.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
      );
      expect(
        transaction.date.isBefore(after.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('note prefers remittance information over everything else', () {
      final transaction = mapEbTransaction(
        _tx(
          remittanceInformation: ['Invoice', '1234'],
          note: 'bank note',
          creditorName: 'Acme Corp',
        ),
        idBankAccount: 1,
      );

      expect(transaction.note, 'Invoice 1234');
    });

    test('note falls back to the bank note when there is no remittance', () {
      final transaction = mapEbTransaction(
        _tx(note: 'bank note', creditorName: 'Acme Corp'),
        idBankAccount: 1,
      );

      expect(transaction.note, 'bank note');
    });

    test('note falls back to the counterparty: debtor on a credit, '
        'creditor on a debit', () {
      final credit = mapEbTransaction(
        _tx(
          creditDebitIndicator: 'CRDT',
          debtorName: 'Jane Payer',
          creditorName: 'Me',
        ),
        idBankAccount: 1,
      );
      expect(credit.note, 'Jane Payer');

      final debit = mapEbTransaction(
        _tx(
          creditDebitIndicator: 'DBIT',
          debtorName: 'Me',
          creditorName: 'Acme Corp',
        ),
        idBankAccount: 1,
      );
      expect(debit.note, 'Acme Corp');
    });

    test('note is null when no information is available at all', () {
      final transaction = mapEbTransaction(_tx(), idBankAccount: 1);
      expect(transaction.note, isNull);
    });

    test('externalId prefers entryReference over transactionId', () {
      expect(
        mapEbTransaction(
          _tx(entryReference: 'entry-1', transactionId: 'txn-1'),
          idBankAccount: 1,
        ).externalId,
        'entry-1',
      );
      expect(
        mapEbTransaction(
          _tx(transactionId: 'txn-1'),
          idBankAccount: 1,
        ).externalId,
        'txn-1',
      );
    });

    test('externalId falls back to a composite key when the ASPSP sends '
        'neither entryReference nor transactionId, so re-syncing the same '
        'transaction is still deduped instead of silently duplicated', () {
      final date = DateTime.utc(2026, 1, 5);
      EbTransaction sameTx() => _tx(
        bookingDate: date,
        amount: 12.5,
        creditDebitIndicator: 'DBIT',
        creditorName: 'Grocer',
        remittanceInformation: ['Weekly shop'],
      );

      final first = mapEbTransaction(sameTx(), idBankAccount: 1);
      final resynced = mapEbTransaction(sameTx(), idBankAccount: 1);

      expect(first.externalId, isNotNull);
      expect(first.externalId, resynced.externalId);
    });

    test('externalId composite fallback differs for genuinely different '
        'transactions on the same day', () {
      final date = DateTime.utc(2026, 1, 5);
      final a = mapEbTransaction(
        _tx(bookingDate: date, amount: 12.5, creditorName: 'Grocer'),
        idBankAccount: 1,
      );
      final b = mapEbTransaction(
        _tx(bookingDate: date, amount: 30, creditorName: 'Landlord'),
        idBankAccount: 1,
      );

      expect(a.externalId, isNot(b.externalId));
    });

    test('recurring is always false and idCategory is always null', () {
      final transaction = mapEbTransaction(_tx(), idBankAccount: 1);
      expect(transaction.recurring, isFalse);
      expect(transaction.idCategory, isNull);
    });
  });
}
