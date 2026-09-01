import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'enable_banking_exception.dart';

const _kPendingAuthorizationKey = 'eb_pending_authorization_v1';

enum PendingAuthorizationPhase { awaitingCallback, sessionStaged }

class PendingBankAuthorization {
  static const _unset = Object();

  final String state;
  final String authorizationId;
  final String authorizationUrl;
  final String applicationId;
  final String aspspName;
  final String aspspCountry;
  final String redirectUri;
  final DateTime expiresAt;
  final DateTime consentValidUntil;
  final int? reconnectConnectionId;
  final int? stagedConnectionId;
  final PendingAuthorizationPhase phase;

  const PendingBankAuthorization({
    required this.state,
    required this.authorizationId,
    required this.authorizationUrl,
    required this.applicationId,
    required this.aspspName,
    required this.aspspCountry,
    required this.redirectUri,
    required this.expiresAt,
    required this.consentValidUntil,
    this.reconnectConnectionId,
    this.stagedConnectionId,
    this.phase = PendingAuthorizationPhase.awaitingCallback,
  });

  PendingBankAuthorization copy({
    Object? stagedConnectionId = _unset,
    PendingAuthorizationPhase? phase,
  }) => PendingBankAuthorization(
    state: state,
    authorizationId: authorizationId,
    authorizationUrl: authorizationUrl,
    applicationId: applicationId,
    aspspName: aspspName,
    aspspCountry: aspspCountry,
    redirectUri: redirectUri,
    expiresAt: expiresAt,
    consentValidUntil: consentValidUntil,
    reconnectConnectionId: reconnectConnectionId,
    stagedConnectionId: stagedConnectionId == _unset
        ? this.stagedConnectionId
        : stagedConnectionId as int?,
    phase: phase ?? this.phase,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'state': state,
    'authorization_id': authorizationId,
    'authorization_url': authorizationUrl,
    'application_id': applicationId,
    'aspsp_name': aspspName,
    'aspsp_country': aspspCountry,
    'redirect_uri': redirectUri,
    'expires_at': expiresAt.toUtc().toIso8601String(),
    'consent_valid_until': consentValidUntil.toUtc().toIso8601String(),
    'reconnect_connection_id': reconnectConnectionId,
    'staged_connection_id': stagedConnectionId,
    'phase': phase.name,
  };

  static PendingBankAuthorization fromJson(Map<String, dynamic> json) {
    try {
      if (json['version'] != 1) {
        throw const FormatException('unsupported pending authorization');
      }
      return PendingBankAuthorization(
        state: json['state'] as String,
        authorizationId: json['authorization_id'] as String,
        authorizationUrl: json['authorization_url'] as String,
        applicationId: json['application_id'] as String,
        aspspName: json['aspsp_name'] as String,
        aspspCountry: json['aspsp_country'] as String,
        redirectUri: json['redirect_uri'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
        consentValidUntil: DateTime.parse(
          json['consent_valid_until'] as String,
        ).toUtc(),
        reconnectConnectionId: json['reconnect_connection_id'] as int?,
        stagedConnectionId: json['staged_connection_id'] as int?,
        phase: PendingAuthorizationPhase.values.byName(json['phase'] as String),
      );
    } catch (error) {
      throw EnableBankingException(
        message: 'Malformed pending bank authorization: $error',
        kind: EnableBankingFailureKind.invalidResponse,
      );
    }
  }
}

abstract class PendingBankAuthorizationStore {
  Future<void> save(PendingBankAuthorization pending);

  Future<PendingBankAuthorization?> read();

  Future<void> clear();
}

class SecurePendingBankAuthorizationStore
    implements PendingBankAuthorizationStore {
  final FlutterSecureStorage _storage;

  const SecurePendingBankAuthorizationStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<void> save(PendingBankAuthorization pending) => _storage.write(
    key: _kPendingAuthorizationKey,
    value: jsonEncode(pending.toJson()),
  );

  @override
  Future<PendingBankAuthorization?> read() async {
    final value = await _storage.read(key: _kPendingAuthorizationKey);
    if (value == null) return null;
    try {
      return PendingBankAuthorization.fromJson(
        jsonDecode(value) as Map<String, dynamic>,
      );
    } on EnableBankingException {
      rethrow;
    } catch (error) {
      throw EnableBankingException(
        message: 'Malformed pending bank authorization: $error',
        kind: EnableBankingFailureKind.invalidResponse,
      );
    }
  }

  @override
  Future<void> clear() => _storage.delete(key: _kPendingAuthorizationKey);
}
