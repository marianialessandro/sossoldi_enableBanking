import 'banking_money.dart';

enum BankingBalanceKind { closingBooked, interimBooked, available, other }

class BankingBalance {
  final String name;
  final BankingMoney amount;
  final BankingBalanceKind kind;
  final DateTime? referenceDate;

  /// Last change of the amount, not the time of the HTTP acquisition.
  final DateTime? observedAt;
  final DateTime? acquiredAt;
  final String? lastCommittedEntryId;

  const BankingBalance({
    required this.name,
    required this.amount,
    required this.kind,
    this.referenceDate,
    this.observedAt,
    this.acquiredAt,
    this.lastCommittedEntryId,
  });
}
