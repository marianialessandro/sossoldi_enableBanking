import '../enable_banking_exception.dart';
import 'eb_amount.dart';

DateTime? _parseDate(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value as String);
}

/// A single transaction as returned by `GET /accounts/{uid}/transactions`.
class EbTransaction {
  final String? entryReference;
  final String? transactionId;
  final String status;
  final DateTime? bookingDate;
  final DateTime? valueDate;
  final DateTime? transactionDate;
  final EbAmount transactionAmount;
  final String creditDebitIndicator;
  final String? creditorName;
  final String? debtorName;
  final List<String> remittanceInformation;
  final String? note;

  const EbTransaction({
    this.entryReference,
    this.transactionId,
    required this.status,
    this.bookingDate,
    this.valueDate,
    this.transactionDate,
    required this.transactionAmount,
    required this.creditDebitIndicator,
    this.creditorName,
    this.debtorName,
    this.remittanceInformation = const [],
    this.note,
  });

  /// Throws [EnableBankingException] (not a raw [TypeError]/[FormatException])
  /// when a required field is missing or of an unexpected type — the ASPSP
  /// occasionally sends a malformed transaction that would otherwise crash
  /// parsing of the whole page (see [EbTransactionsPage.fromJson], which
  /// catches this to skip just the one bad transaction).
  static EbTransaction fromJson(Map<String, dynamic> json) {
    try {
      return EbTransaction(
        entryReference: json['entry_reference'] as String?,
        transactionId: json['transaction_id'] as String?,
        status: json['status'] as String,
        bookingDate: _parseDate(json['booking_date']),
        valueDate: _parseDate(json['value_date']),
        transactionDate: _parseDate(json['transaction_date']),
        transactionAmount: EbAmount.fromJson(
          json['transaction_amount'] as Map<String, dynamic>,
        ),
        creditDebitIndicator: json['credit_debit_indicator'] as String,
        creditorName:
            (json['creditor'] as Map<String, dynamic>?)?['name'] as String?,
        debtorName:
            (json['debtor'] as Map<String, dynamic>?)?['name'] as String?,
        remittanceInformation:
            ((json['remittance_information'] as List?) ?? const [])
                .map((e) => e as String)
                .toList(),
        note: json['note'] as String?,
      );
    } catch (e) {
      throw EnableBankingException(
        message: 'Malformed transaction from Enable Banking: $e',
      );
    }
  }

  /// Signed amount: positive for credits (`CRDT`), negative otherwise.
  ///
  /// Anything that is not `CRDT` (e.g. `DBIT`/`DBDT`) is treated as an outflow.
  num get signedAmount => creditDebitIndicator == 'CRDT'
      ? transactionAmount.amount
      : -transactionAmount.amount;

  /// Stable dedup key: `entry_reference` when present, else `transaction_id`,
  /// else a composite of date/amount/direction/description.
  ///
  /// Not every ASPSP populates either bank-provided id (observed in
  /// production with at least one ASPSP) — without this fallback,
  /// `TransactionsRepository.insertMissing` has nothing to dedup against and
  /// re-inserts the same transaction on every re-sync. The composite key is
  /// a best effort, not a guarantee: two genuinely distinct transactions
  /// with identical date/amount/direction/description on the same account
  /// would collide and the second be skipped as a false duplicate — a
  /// safer failure mode than unbounded duplication.
  String? get stableId {
    if (entryReference != null) return entryReference;
    if (transactionId != null) return transactionId;

    final date = bookingDate ?? valueDate ?? transactionDate;
    if (date == null) return null;

    return [
      date.toIso8601String(),
      transactionAmount.amount,
      creditDebitIndicator,
      remittanceInformation.join(' '),
      note ?? '',
      creditorName ?? '',
      debtorName ?? '',
    ].join('|');
  }

  bool get isBooked => status == 'BOOK';
}
