import 'models/bank_money.dart';
import 'models/bank_remote_transaction.dart';
import 'models/eb_balance.dart';

class BankBalanceSnapshot {
  final BankMoney money;
  final DateTime at;

  const BankBalanceSnapshot(this.money, this.at);
}

/// Reconciliation uses booked balances whose last entry is in this fetched batch.
BankBalanceSnapshot? selectBankBalance(
  List<EbBalance> balances,
  List<BankRemoteTransaction> transactions,
  String currency,
  DateTime? serverTime,
) {
  if (serverTime == null) return null;
  final booked = transactions.where((item) => item.status == 'BOOK').toList();
  final candidates = <BankBalanceSnapshot>[];
  for (final balance in balances) {
    if (balance.balanceAmount.currency != currency ||
        !const {'CLBD', 'ITBD'}.contains(balance.balanceType)) {
      continue;
    }
    final marker = BankRemoteTransaction.normalizeId(
      balance.lastCommittedTransaction,
    );
    if (marker == null ||
        !booked.any((item) => item.entryReference == marker)) {
      continue;
    }
    final reference = balance.referenceDate;
    final at =
        balance.lastChangeDateTime ??
        (reference == null
            ? null
            : DateTime.utc(
                reference.year,
                reference.month,
                reference.day,
                23,
                59,
                59,
              ));
    if (at == null ||
        at.isAfter(serverTime) ||
        serverTime.difference(at) > const Duration(days: 2)) {
      continue;
    }
    if (booked.any((item) => item.date.isAfter(at))) continue;
    final markerDate = booked
        .firstWhere((item) => item.entryReference == marker)
        .date;
    if (booked.any((item) => item.date.isAfter(markerDate))) continue;
    final money = BankMoney.parse(balance.balanceAmount.exactAmount, currency);
    money.projection;
    candidates.add(BankBalanceSnapshot(money, at));
  }
  candidates.sort((first, second) => second.at.compareTo(first.at));
  if (candidates.isEmpty) return null;
  final newest = candidates.first;
  if (candidates.any(
    (item) =>
        item.at == newest.at &&
        item.money.minorUnits != newest.money.minorUnits,
  )) {
    return null;
  }
  return newest;
}
