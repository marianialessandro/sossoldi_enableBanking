import 'dart:developer' as developer;

import '../enable_banking_exception.dart';
import 'eb_transaction.dart';

/// Paginated envelope from `GET /accounts/{uid}/transactions`.
///
/// [continuationKey] is echoed back on the next request to fetch more pages.
class EbTransactionsPage {
  final List<EbTransaction> transactions;
  final String? continuationKey;

  const EbTransactionsPage({
    this.transactions = const [],
    this.continuationKey,
  });

  /// A single malformed transaction (see [EbTransaction.fromJson]) is
  /// logged and dropped rather than failing the whole page: the other,
  /// valid transactions on the same page/account must still be synced.
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
