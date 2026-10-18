class ObsoleteBankConnection {
  final String providerId;
  final String applicationId;
  final String authorizationId;
  final String remoteConnectionId;
  final int attemptRevision;
  final String reason;

  const ObsoleteBankConnection({
    required this.providerId,
    required this.applicationId,
    required this.authorizationId,
    required this.remoteConnectionId,
    required this.attemptRevision,
    required this.reason,
  });

  bool sameConnection(ObsoleteBankConnection other) =>
      providerId == other.providerId &&
      applicationId == other.applicationId &&
      remoteConnectionId == other.remoteConnectionId;

  Map<String, Object> toJson() => {
    'provider_id': providerId,
    'application_id': applicationId,
    'authorization_id': authorizationId,
    'remote_connection_id': remoteConnectionId,
    'attempt_revision': attemptRevision,
    'reason': reason,
  };

  factory ObsoleteBankConnection.fromJson(Map<String, dynamic> json) =>
      ObsoleteBankConnection(
        providerId: json['provider_id'] as String,
        applicationId: json['application_id'] as String,
        authorizationId: json['authorization_id'] as String,
        remoteConnectionId: json['remote_connection_id'] as String,
        attemptRevision: json['attempt_revision'] as int,
        reason: json['reason'] as String,
      );
}
