import '../enable_banking_exception.dart';
import 'eb_amount.dart';

DateTime? _parseDate(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value as String);
}

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

  // Wrap parse errors so callers get EnableBankingException instead of a
  // raw TypeError/FormatException.
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

  num get signedAmount => creditDebitIndicator == 'CRDT'
      ? transactionAmount.amount
      : -transactionAmount.amount;

  // Falls back to a composite key when the ASPSP sends neither
  // entry_reference nor transaction_id, so re-syncs can still dedup.
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
