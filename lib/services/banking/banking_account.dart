import 'banking_reference.dart';

class BankingAccountDescriptor {
  final BankingAccountReference? reference;
  final String? iban;
  final String? name;
  final String? details;
  final String? currency;
  final String? product;
  final String? accountType;
  final String? usage;
  final Set<String> identityKeys;

  BankingAccountDescriptor({
    this.reference,
    this.iban,
    this.name,
    this.details,
    this.currency,
    this.product,
    this.accountType,
    this.usage,
    Iterable<String>? identityKeys,
  }) : identityKeys = Set.unmodifiable(
         identityKeys ?? reference?.identityKeys ?? const [],
       );

  BankingAccount? get account => reference == null
      ? null
      : BankingAccount(
          reference: reference!,
          iban: iban,
          name: name,
          details: details,
          currency: currency,
          product: product,
          accountType: accountType,
          usage: usage,
        );
}

class BankingAccount {
  final BankingAccountReference reference;
  final String? iban;
  final String? name;
  final String? details;
  final String? currency;
  final String? product;
  final String? accountType;
  final String? usage;

  const BankingAccount({
    required this.reference,
    this.iban,
    this.name,
    this.details,
    this.currency,
    this.product,
    this.accountType,
    this.usage,
  });
}
