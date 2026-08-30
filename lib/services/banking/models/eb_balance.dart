import 'eb_amount.dart';

class EbBalance {
  final String name;
  final EbAmount balanceAmount;
  final String? balanceType;

  const EbBalance({
    required this.name,
    required this.balanceAmount,
    this.balanceType,
  });

  static EbBalance fromJson(Map<String, dynamic> json) => EbBalance(
    name: json['name'] as String,
    balanceAmount: EbAmount.fromJson(
      json['balance_amount'] as Map<String, dynamic>,
    ),
    balanceType: json['balance_type'] as String?,
  );
}

num? preferredEbBalanceAmount(Iterable<EbBalance> balances) {
  final available = balances.toList();
  if (available.isEmpty) return null;

  // Prefer accounting/booked balances so the total is consistent with the
  // BOOK transactions persisted by the sync service.
  for (final type in const ['CLBD', 'ITBD', 'CLAV', 'ITAV']) {
    for (final balance in available) {
      if (balance.balanceType?.toUpperCase() == type) {
        return balance.balanceAmount.amount;
      }
    }
  }
  return available.first.balanceAmount.amount;
}
