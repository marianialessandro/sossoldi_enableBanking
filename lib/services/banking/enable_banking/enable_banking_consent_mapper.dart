import '../banking_authorization.dart';
import '../banking_connection.dart';
import '../banking_reference.dart';
import 'enable_banking_account_mapper.dart';
import 'enable_banking_errors.dart';
import 'enable_banking_institution_mapper.dart';
import 'models/aspsp.dart';
import 'models/eb_auth.dart';
import 'models/eb_account.dart';
import 'models/eb_session.dart';
import 'models/eb_session_details.dart';

class EnableBankingConsentMapper {
  final _institutions = const EnableBankingInstitutionMapper();
  final _accounts = const EnableBankingAccountMapper();

  const EnableBankingConsentMapper();

  BankingAuthorization authorization(EbAuthorization value) {
    final uri = Uri.parse(value.url);
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Invalid authorization URL');
    }
    return BankingAuthorization(
      providerId: enableBankingId,
      authorizationId: value.authorizationId,
      uri: uri,
    );
  }

  BankingConnectionResult created(EbSession value) {
    final descriptors = value.accounts.map(_accounts.descriptor).toList();
    final accounts = descriptors.map((item) => item.account).nonNulls.toList();
    final connection = BankingConnection(
      reference: BankingConnectionReference(
        providerId: enableBankingId,
        remoteId: value.sessionId,
      ),
      institution: _institutions.institution(
        Aspsp(
          name: value.aspspName,
          country: value.aspspCountry,
          psuTypes: [if (value.psuType != null) value.psuType!],
        ),
      ),
      validUntil: value.validUntil,
      status: BankingConnectionStatus.active,
      accounts: accounts.map((account) => account.reference).toList(),
      accountDescriptors: descriptors,
    );
    return BankingConnectionResult(connection: connection, accounts: accounts);
  }

  BankingConnection connection(
    EbSessionDetails value,
    BankingConnectionReference reference,
  ) {
    final descriptors = [
      for (final account in value.accountsData)
        _accounts.descriptor(
          EbAccount(
            uid: account.uid,
            iban: account.iban,
            name: account.name,
            details: account.details,
            currency: account.currency,
            product: account.product,
            cashAccountType: account.cashAccountType,
            usage: account.usage,
            identificationHash: account.identificationHash,
            identificationHashes: account.identificationHashes,
          ),
        ),
      for (final uid in value.accountUids)
        if (!value.accountsData.any((account) => account.uid == uid))
          _accounts.descriptor(EbAccount(uid: uid)),
    ];
    return BankingConnection(
      reference: reference,
      institution: _institutions.institution(
        Aspsp(
          name: value.aspspName,
          country: value.aspspCountry,
          psuTypes: [value.psuType],
        ),
      ),
      validUntil: value.validUntil,
      status: switch (value.status) {
        EbSessionStatus.authorized => BankingConnectionStatus.active,
        EbSessionStatus.pendingAuthorization ||
        EbSessionStatus.returnedFromBank => BankingConnectionStatus.pending,
        EbSessionStatus.cancelled => BankingConnectionStatus.cancelled,
        EbSessionStatus.closed => BankingConnectionStatus.closed,
        EbSessionStatus.expired => BankingConnectionStatus.expired,
        EbSessionStatus.invalid => BankingConnectionStatus.invalid,
        EbSessionStatus.revoked => BankingConnectionStatus.revoked,
      },
      accounts: descriptors.map((item) => item.reference).nonNulls.toList(),
      accountDescriptors: descriptors,
      createdAt: value.created,
      authorizedAt: value.authorized,
      closedAt: value.closed,
    );
  }
}
