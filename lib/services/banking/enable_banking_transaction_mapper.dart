import '../../model/transaction.dart';
import 'models/eb_transaction.dart';

const _kMaxNoteLength = 280;

String _truncate(String value) => value.length <= _kMaxNoteLength
    ? value
    : value.substring(0, _kMaxNoteLength);

// Falls back through remittance info, note, then counterparty name (debtor
// for a credit, creditor for a debit).
String? _buildNote(EbTransaction tx) {
  final remittance = tx.remittanceInformation
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join(' ');
  if (remittance.isNotEmpty) return _truncate(remittance);

  final note = tx.note?.trim();
  if (note != null && note.isNotEmpty) return _truncate(note);

  final counterparty = tx.creditDebitIndicator == 'CRDT'
      ? tx.debtorName
      : tx.creditorName;
  return counterparty != null && counterparty.trim().isNotEmpty
      ? _truncate(counterparty.trim())
      : null;
}

Transaction mapEbTransaction(EbTransaction tx, {required int idBankAccount}) {
  final signedAmount = tx.signedAmount;

  return Transaction(
    // amount is always positive in this app; the sign lives in type.
    amount: signedAmount.abs(),
    type: signedAmount >= 0 ? TransactionType.income : TransactionType.expense,
    date:
        tx.bookingDate ?? tx.transactionDate ?? tx.valueDate ?? DateTime.now(),
    note: _buildNote(tx),
    idBankAccount: idBankAccount,
    recurring: false,
    externalId: tx.stableId,
  );
}
