import 'bank_institution.dart';
import 'banking_account.dart';
import 'banking_reference.dart';

enum BankingConnectionStatus {
  pending,
  active,
  cancelled,
  closed,
  expired,
  invalid,
  revoked,
}

class BankingConnection {
  final BankingConnectionReference reference;
  final BankInstitution institution;
  final DateTime validUntil;
  final BankingConnectionStatus status;
  final List<BankingAccountReference> accounts;
  final List<BankingAccountDescriptor> accountDescriptors;
  final DateTime? createdAt;
  final DateTime? authorizedAt;
  final DateTime? closedAt;

  BankingConnection({
    required this.reference,
    required this.institution,
    required this.validUntil,
    required this.status,
    required List<BankingAccountReference> accounts,
    List<BankingAccountDescriptor>? accountDescriptors,
    this.createdAt,
    this.authorizedAt,
    this.closedAt,
  }) : accounts = List.unmodifiable(accounts),
       accountDescriptors = List.unmodifiable(
         accountDescriptors ??
             accounts.map(
               (reference) => BankingAccountDescriptor(reference: reference),
             ),
       );

  bool isExpiredAt(DateTime now) => !now.isBefore(validUntil);
}

class BankingConnectionResult {
  final BankingConnection connection;
  final List<BankingAccount> accounts;

  BankingConnectionResult({
    required this.connection,
    required List<BankingAccount> accounts,
  }) : accounts = List.unmodifiable(accounts);
}
