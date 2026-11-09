import '../banking_account.dart';
import '../banking_reference.dart';
import 'enable_banking_errors.dart';
import 'models/eb_account.dart';

class EnableBankingAccountMapper {
  const EnableBankingAccountMapper();

  BankingAccount account(EbAccount value) {
    final result = descriptor(value).account;
    if (result == null) {
      throw const FormatException('Account identifier missing');
    }
    return result;
  }

  BankingAccountDescriptor descriptor(EbAccount value) {
    final uid = value.uid;
    if (uid != null &&
        (uid.trim().isEmpty ||
            uid.contains('/') ||
            uid == '.' ||
            uid == '..')) {
      throw const FormatException('Invalid account identifier');
    }
    return BankingAccountDescriptor(
      reference: uid == null
          ? null
          : BankingAccountReference(
              providerId: enableBankingId,
              remoteId: uid,
              identityKeys: [
                if (value.identificationHash != null) value.identificationHash!,
                ...value.identificationHashes,
              ],
            ),
      iban: value.iban,
      name: value.name,
      details: value.details,
      currency: value.currency,
      product: value.product,
      accountType: value.cashAccountType,
      usage: value.usage,
      identityKeys: value.stableHashes,
    );
  }
}
