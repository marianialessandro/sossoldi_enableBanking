import 'banking_authorization.dart';
import 'banking_connection.dart';
import 'banking_reference.dart';

/// Optional receipt capability; alternative providers retain the original consent contract.
abstract interface class BankConnectionReceiptSource {
  Future<BankingConnectionResult> createConnectionWithReceipt(
    String authorizationCode,
    Future<void> Function(BankingConnectionReference) onReference,
  );
}

abstract interface class BankConsentService {
  Future<BankingAuthorization> startAuthorization(
    BankingAuthorizationRequest request,
  );

  /// Exchanges an authorization code after the application lifecycle has validated and accepted the callback.
  Future<BankingConnectionResult> createConnection(String authorizationCode);
  Future<BankingConnection> getConnection(BankingConnectionReference reference);
  Future<void> revokeConnection(BankingConnectionReference reference);
}
