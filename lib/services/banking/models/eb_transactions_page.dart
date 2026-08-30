import 'dart:developer' as developer;

import '../enable_banking_exception.dart';
import 'eb_transaction.dart';

class EbTransactionsPage {
  final List<EbTransaction> transactions;
  final String? continuationKey;

  const EbTransactionsPage({
    this.transactions = const [],
    this.continuationKey,
  });

  // Skip malformed transactions instead of failing the whole page.
  static EbTransactionsPage fromJson(Map<String, dynamic> json) {
    final raw = (json['transactions'] as List?) ?? const [];
    final transactions = <EbTransaction>[];
    for (final entry in raw) {
      try {
        transactions.add(EbTransaction.fromJson(entry as Map<String, dynamic>));
      } on EnableBankingException catch (e) {
        developer.log(
          'Skipping malformed transaction: ${e.message}',
          name: 'EbTransactionsPage',
        );
      }
    }
    return EbTransactionsPage(
      transactions: transactions,
      continuationKey: json['continuation_key'] as String?,
    );
  }
}
