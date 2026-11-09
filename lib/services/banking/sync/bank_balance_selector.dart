import 'bank_money.dart';
import 'bank_remote_transaction.dart';
import '../banking_balance.dart';

class BankBalanceSnapshot {
  final BankMoney money;
  final DateTime at;

  const BankBalanceSnapshot(this.money, this.at);
}

class _BalanceCandidate {
  final BankBalanceSnapshot snapshot;
  final DateTime? reference;
  final DateTime? changed;

  const _BalanceCandidate(this.snapshot, this.reference, this.changed);

  bool isAfter(_BalanceCandidate other) {
    if (reference != null && other.reference != null) {
      final order = reference!.compareTo(other.reference!);
      if (order != 0) return order > 0;
    } else if (reference != other.reference) {
      return false;
    }
    return changed != null &&
        other.changed != null &&
        changed!.isAfter(other.changed!);
  }
}

/// Reconciliation uses booked balances whose last entry is in this fetched batch.
BankBalanceSnapshot? selectBankBalance(
  List<BankingBalance> balances,
  List<BankRemoteTransaction> transactions,
  String currency,
  DateTime? serverTime, {
  bool coherentRead = false,
}) {
  if (serverTime == null) return null;
  final booked = transactions.where((item) => item.status == 'BOOK').toList();
  final candidates = <_BalanceCandidate>[];
  for (final balance in balances) {
    if (balance.amount.currency != currency ||
        !const {
          BankingBalanceKind.closingBooked,
          BankingBalanceKind.interimBooked,
        }.contains(balance.kind)) {
      continue;
    }
    final marker = BankRemoteTransaction.normalizeId(
      balance.lastCommittedEntryId,
    );
    final reference = balance.referenceDate;
    final acquired = balance.acquiredAt?.toUtc();
    final changed = balance.observedAt?.toUtc();
    if (acquired != null && acquired.isAfter(serverTime)) continue;
    final bound = acquired ?? serverTime;
    if (changed != null && changed.isAfter(bound)) continue;
    var currentReference = false;
    if (reference != null) {
      final day = DateTime.utc(reference.year, reference.month, reference.day);
      if (acquired != null) {
        final acquiredDay = DateTime.utc(
          acquired.year,
          acquired.month,
          acquired.day,
        );
        currentReference = day == acquiredDay;
        if (!currentReference) {
          // The provider supplies no bank timezone; this interval proves only civil possibility.
          final earliest = day.subtract(const Duration(hours: 14));
          final latest = day.add(const Duration(days: 1, hours: 12));
          currentReference =
              coherentRead &&
              !acquired.isBefore(earliest) &&
              acquired.isBefore(latest);
        }
      }
      if (!currentReference) continue;
    }
    final freshChange =
        changed != null && bound.difference(changed) <= const Duration(days: 2);
    if (!currentReference && !freshChange) continue;
    final at = acquired ?? changed;
    if (at == null || at.isAfter(serverTime)) continue;
    if (booked.any((item) => item.date.isAfter(at))) continue;
    final money = BankMoney.parse(balance.amount.decimalAmount, currency);
    final emptyZero =
        booked.isEmpty && marker == null && money.minorUnits == BigInt.zero;
    if (!emptyZero) {
      if (marker == null ||
          !booked.any((item) => item.entryReference == marker)) {
        continue;
      }
      final markerDate = booked
          .firstWhere((item) => item.entryReference == marker)
          .date;
      if (booked.any((item) => item.date.isAfter(markerDate))) continue;
    }
    money.projection;
    candidates.add(
      _BalanceCandidate(
        BankBalanceSnapshot(money, at),
        reference == null
            ? null
            : DateTime.utc(reference.year, reference.month, reference.day),
        changed,
      ),
    );
  }
  if (candidates.isEmpty) return null;
  // Acquisition bounds persistence, while comparable civil references and last changes establish precedence.
  final newest = candidates
      .where((item) => !candidates.any((other) => other.isAfter(item)))
      .toList();
  if (newest.any(
    (item) =>
        item.snapshot.money.minorUnits !=
        newest.first.snapshot.money.minorUnits,
  )) {
    return null;
  }
  newest.sort(
    (first, second) => second.snapshot.at.compareTo(first.snapshot.at),
  );
  return newest.first.snapshot;
}
