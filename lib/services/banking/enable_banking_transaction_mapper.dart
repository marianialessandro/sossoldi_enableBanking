import '../../model/transaction.dart';
import 'models/eb_transaction.dart';

const _kMaxNoteLength = 280;

String _truncate(String value) => value.length <= _kMaxNoteLength
    ? value
    : value.substring(0, _kMaxNoteLength);

/// First non-empty of: remittance information, the bank's own `note`, or the
/// counterparty name — the debtor paid a credit into this account, the
/// creditor received a debit out of it.
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

/// Maps one Enable Banking transaction onto the app's own [Transaction]
/// model, ready for `TransactionsRepository.insertMissing`. Pure and
/// side-effect free so it can be unit tested without a database.
Transaction mapEbTransaction(EbTransaction tx, {required int idBankAccount}) {
  final signedAmount = tx.signedAmount;

  return Transaction(
    // `amount` is always a positive magnitude in this app — every balance
    // query (e.g. AccountRepository.getAccountSum) adds it for `income` and
    // subtracts it for `expense` — so the sign only ever lives in `type`.
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
