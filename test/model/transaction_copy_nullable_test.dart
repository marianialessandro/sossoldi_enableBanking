import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/transaction.dart';

void main() {
  final instant = DateTime.utc(2032, 9, 7, 12);
  Transaction movement() => Transaction(
    id: 7,
    date: instant,
    amount: 10,
    type: TransactionType.transfer,
    note: 'Personal note',
    idBankAccount: 1,
    idBankAccountTransfer: 2,
    idCategory: 11,
    recurring: true,
    idRecurringTransaction: 42,
    createdAt: instant,
    updatedAt: instant,
  );

  test('RG02 omitted nullable arguments retain the original values', () {
    final copied = movement().copy(amount: 20);
    expect(copied.note, 'Personal note');
    expect(copied.idCategory, 11);
    expect(copied.idBankAccountTransfer, 2);
    expect(copied.idRecurringTransaction, 42);
    expect(copied.id, 7);
    expect(copied.amount, 20);
  });

  test(
    'RG02 explicit null clears nullable fields and preserves other data',
    () {
      final copied = movement().copy(
        note: null,
        idCategory: null,
        idBankAccountTransfer: null,
        idRecurringTransaction: null,
        recurring: false,
      );
      expect(copied.note, isNull);
      expect(copied.idCategory, isNull);
      expect(copied.idBankAccountTransfer, isNull);
      expect(copied.idRecurringTransaction, isNull);
      expect(copied.recurring, isFalse);
      expect(copied.idBankAccount, 1);
      expect(copied.date, instant);
      expect(copied.amount, 10);
      expect(copied.type, TransactionType.transfer);
    },
  );

  test('RG02 nullable replacement still accepts non-null values', () {
    final copied = movement().copy(
      id: null,
      note: 'Replacement',
      idCategory: 12,
      idBankAccountTransfer: 3,
      idRecurringTransaction: 43,
    );
    expect(copied.id, isNull);
    expect(copied.note, 'Replacement');
    expect(copied.idCategory, 12);
    expect(copied.idBankAccountTransfer, 3);
    expect(copied.idRecurringTransaction, 43);
  });
}
