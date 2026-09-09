import 'dart:convert';

import 'bank_money.dart';
import 'eb_transaction.dart';

/// Bank-owned values are separate from editable category and note projections.
class BankRemoteTransaction {
  final String key;
  final String? entryReference;
  final String? transactionId;
  final String status;
  final DateTime date;
  final BankMoney money;
  final String note;

  BankRemoteTransaction({
    required this.key,
    required this.entryReference,
    required this.transactionId,
    required this.status,
    required this.date,
    required this.money,
    required this.note,
  });

  static String? normalizeId(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  factory BankRemoteTransaction.fromTransaction(
    EbTransaction item,
    String currency,
  ) {
    if (!const {
      'BOOK',
      'PDNG',
      'CNCL',
      'HOLD',
      'RJCT',
      'SCHD',
    }.contains(item.status)) {
      throw const FormatException('Unknown transaction status');
    }
    if (!const {'CRDT', 'DBIT'}.contains(item.creditDebitIndicator)) {
      throw const FormatException('Unknown credit/debit indicator');
    }
    var money = BankMoney.parse(
      item.transactionAmount.exactAmount,
      item.transactionAmount.currency,
    );
    if (money.currency != currency || money.minorUnits.isNegative) {
      throw const FormatException('Invalid transaction currency or magnitude');
    }
    if (item.creditDebitIndicator == 'DBIT') money = money.negated;
    final sourceDate =
        item.bookingDate ?? item.transactionDate ?? item.valueDate;
    if (sourceDate == null) {
      throw const FormatException('Missing transaction date');
    }
    final date = DateTime.utc(
      sourceDate.year,
      sourceDate.month,
      sourceDate.day,
    );
    final reference = normalizeId(item.entryReference);
    final note = item.remittanceInformation.isNotEmpty
        ? item.remittanceInformation.join(' ').trim()
        : (item.note ??
                  (item.creditDebitIndicator == 'CRDT'
                      ? item.debtorName
                      : item.creditorName) ??
                  '')
              .trim();
    if (note.length > 8192 || (reference?.length ?? 0) > 1024) {
      throw const FormatException('Transaction text exceeds supported size');
    }
    final fingerprint = jsonEncode([
      date.toIso8601String(),
      money.currency,
      money.minorUnits.toString(),
      item.creditorName?.trim(),
      item.debtorName?.trim(),
      note.replaceAll(RegExp(r'\s+'), ' '),
    ]);
    final key = reference == null
        ? 'fp:${base64Url.encode(utf8.encode(fingerprint))}'
        : 'ref:$reference';
    money.projection;
    return BankRemoteTransaction(
      key: key,
      entryReference: reference,
      transactionId: normalizeId(item.transactionId),
      status: item.status,
      date: date,
      money: money,
      note: note,
    );
  }
}
