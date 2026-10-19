import '../../../model/bank_connection.dart';
import '../banking_connection.dart';
import 'pending_bank_authorization.dart';

/// An opaque capability for one authorization generation on one storage scope.
class BankAuthorizationOwner {
  final Object scope;
  final Object generation;
  final int revision;
  final int? credentialRevision;
  final PendingBankAuthorization? pending;
  final String bankName;

  const BankAuthorizationOwner({
    required this.scope,
    required this.generation,
    required this.revision,
    required this.credentialRevision,
    required this.bankName,
    this.pending,
  });

  bool sameGeneration(BankAuthorizationOwner other) =>
      identical(scope, other.scope) &&
      identical(generation, other.generation) &&
      revision == other.revision &&
      credentialRevision == other.credentialRevision;
}

class AuthorizationAttempt {
  final Uri url;
  final DateTime consentValidUntil;
  final BankAuthorizationOwner? owner;

  const AuthorizationAttempt({
    required this.url,
    required this.consentValidUntil,
    this.owner,
  });
}

class AuthorizationLaunchResult {
  final Uri url;
  final bool opened;
  final BankAuthorizationOwner? owner;

  const AuthorizationLaunchResult({
    required this.url,
    required this.opened,
    this.owner,
  });
}

/// Proof returned only after protected SQL finalization; pending cleanup is independent.
class BankDisconnectFinalization {
  final BankConnection connection;
  final PendingBankAuthorization? pendingCleanup;
  const BankDisconnectFinalization({
    required this.connection,
    this.pendingCleanup,
  });
}

class StagedBankConnection {
  final BankConnection connection;
  final BankingConnectionResult? createdConnection;

  const StagedBankConnection({
    required this.connection,
    this.createdConnection,
  });
}

class ResumableBankConnection {
  final BankConnection connection;
  final BankingConnection details;

  const ResumableBankConnection({
    required this.connection,
    required this.details,
  });
}

typedef AuthorizationUrlLauncher = Future<bool> Function(Uri url);
