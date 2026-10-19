import 'banking_account.dart';

enum BankingImportStatus {
  idle,
  loading,
  cancelled,
  manualContextRequired,
  empty,
  partial,
  allFailed,
  unavailable,
  ready,
  terminal,
  pending,
  obsolete,
}

enum BankingAccountImportStatus { available, unavailable, failed }

enum BankingImportFailureScope { account, consent, application }

class BankingAccountImportOutcome {
  final BankingAccountDescriptor descriptor;
  final BankingAccount? account;
  final BankingAccountImportStatus status;
  final BankingImportFailureScope? scope;
  final String? code;
  final num? balance;
  const BankingAccountImportOutcome({
    required this.descriptor,
    required this.status,
    this.account,
    this.scope,
    this.code,
    this.balance,
  });
}

BankingImportStatus bankingImportStatus(
  List<BankingAccountImportOutcome> outcomes,
) {
  if (outcomes.isEmpty) return BankingImportStatus.empty;
  final available = outcomes.where((item) => item.account != null).length;
  if (available == outcomes.length &&
      outcomes.every((item) => item.code == null)) {
    return BankingImportStatus.ready;
  }
  if (available > 0) return BankingImportStatus.partial;
  if (outcomes.every(
    (item) => item.status == BankingAccountImportStatus.unavailable,
  )) {
    return BankingImportStatus.unavailable;
  }
  return BankingImportStatus.allFailed;
}
