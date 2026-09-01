import 'base_entity.dart';

const String bankConnectionTable = 'bankConnection';
const String bankAccountIdentityTable = 'bankAccountIdentity';

class BankConnectionFields extends BaseEntityFields {
  static String id = BaseEntityFields.getId;
  static String aspspName = 'aspspName';
  static String aspspCountry = 'aspspCountry';
  static String applicationId = 'applicationId';
  static String sessionId = 'sessionId';
  static String pendingSessionId = 'pendingSessionId';
  static String pendingAuthorizationId = 'pendingAuthorizationId';
  static String validUntil = 'validUntil';
  static String pendingValidUntil = 'pendingValidUntil';
  static String status = 'status';
  static String psuType = 'psuType';
  static String createdAt = BaseEntityFields.getCreatedAt;
  static String updatedAt = BaseEntityFields.getUpdatedAt;

  static final List<String> allFields = [
    id,
    aspspName,
    aspspCountry,
    applicationId,
    sessionId,
    pendingSessionId,
    pendingAuthorizationId,
    validUntil,
    pendingValidUntil,
    status,
    psuType,
    createdAt,
    updatedAt,
  ];
}

class BankAccountIdentityFields {
  static String connectionId = 'connectionId';
  static String bankAccountId = 'bankAccountId';
  static String identificationHash = 'identificationHash';
}

enum BankConnectionStatus {
  authorizing,
  awaitingImport,
  active,
  expired,
  revoked,
  reauthRequired,
  revocationPending,
  disconnected;

  String get code => switch (this) {
    BankConnectionStatus.authorizing => 'AUTHORIZING',
    BankConnectionStatus.awaitingImport => 'AWAITING_IMPORT',
    BankConnectionStatus.active => 'ACTIVE',
    BankConnectionStatus.expired => 'EXPIRED',
    BankConnectionStatus.revoked => 'REVOKED',
    BankConnectionStatus.reauthRequired => 'REAUTH_REQUIRED',
    BankConnectionStatus.revocationPending => 'REVOCATION_PENDING',
    BankConnectionStatus.disconnected => 'DISCONNECTED',
  };

  static BankConnectionStatus fromJson(String code) =>
      BankConnectionStatus.values.firstWhere(
        (status) => status.code == code,
        orElse: () =>
            throw FormatException('Unknown bank connection status: $code'),
      );
}

class BankConnection extends BaseEntity {
  static const _unset = Object();

  final String aspspName;
  final String aspspCountry;
  final String applicationId;
  final String? sessionId;
  final String? pendingSessionId;
  final String? pendingAuthorizationId;
  final DateTime? validUntil;
  final DateTime? pendingValidUntil;
  final BankConnectionStatus status;
  final String psuType;

  const BankConnection({
    super.id,
    required this.aspspName,
    required this.aspspCountry,
    required this.applicationId,
    this.sessionId,
    this.pendingSessionId,
    this.pendingAuthorizationId,
    this.validUntil,
    this.pendingValidUntil,
    required this.status,
    this.psuType = 'personal',
    super.createdAt,
    super.updatedAt,
  });

  BankConnection copy({
    int? id,
    String? aspspName,
    String? aspspCountry,
    String? applicationId,
    Object? sessionId = _unset,
    Object? pendingSessionId = _unset,
    Object? pendingAuthorizationId = _unset,
    Object? validUntil = _unset,
    Object? pendingValidUntil = _unset,
    BankConnectionStatus? status,
    String? psuType,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => BankConnection(
    id: id ?? this.id,
    aspspName: aspspName ?? this.aspspName,
    aspspCountry: aspspCountry ?? this.aspspCountry,
    applicationId: applicationId ?? this.applicationId,
    sessionId: sessionId == _unset ? this.sessionId : sessionId as String?,
    pendingSessionId: pendingSessionId == _unset
        ? this.pendingSessionId
        : pendingSessionId as String?,
    pendingAuthorizationId: pendingAuthorizationId == _unset
        ? this.pendingAuthorizationId
        : pendingAuthorizationId as String?,
    validUntil: validUntil == _unset
        ? this.validUntil
        : validUntil as DateTime?,
    pendingValidUntil: pendingValidUntil == _unset
        ? this.pendingValidUntil
        : pendingValidUntil as DateTime?,
    status: status ?? this.status,
    psuType: psuType ?? this.psuType,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  static BankConnection fromJson(Map<String, Object?> json) => BankConnection(
    id: json[BankConnectionFields.id] as int?,
    aspspName: json[BankConnectionFields.aspspName] as String,
    aspspCountry: json[BankConnectionFields.aspspCountry] as String,
    applicationId: json[BankConnectionFields.applicationId] as String,
    sessionId: json[BankConnectionFields.sessionId] as String?,
    pendingSessionId: json[BankConnectionFields.pendingSessionId] as String?,
    pendingAuthorizationId:
        json[BankConnectionFields.pendingAuthorizationId] as String?,
    validUntil: _date(json[BankConnectionFields.validUntil]),
    pendingValidUntil: _date(json[BankConnectionFields.pendingValidUntil]),
    status: BankConnectionStatus.fromJson(
      json[BankConnectionFields.status] as String,
    ),
    psuType: json[BankConnectionFields.psuType] as String? ?? 'personal',
    createdAt: _date(json[BankConnectionFields.createdAt]),
    updatedAt: _date(json[BankConnectionFields.updatedAt]),
  );

  Map<String, Object?> toJson({bool update = false, DateTime? clock}) {
    final now = (clock ?? DateTime.now()).toUtc().toIso8601String();
    return {
      BankConnectionFields.id: id,
      BankConnectionFields.aspspName: aspspName,
      BankConnectionFields.aspspCountry: aspspCountry,
      BankConnectionFields.applicationId: applicationId,
      BankConnectionFields.sessionId: sessionId,
      BankConnectionFields.pendingSessionId: pendingSessionId,
      BankConnectionFields.pendingAuthorizationId: pendingAuthorizationId,
      BankConnectionFields.validUntil: validUntil?.toUtc().toIso8601String(),
      BankConnectionFields.pendingValidUntil: pendingValidUntil
          ?.toUtc()
          .toIso8601String(),
      BankConnectionFields.status: status.code,
      BankConnectionFields.psuType: psuType,
      BankConnectionFields.createdAt: update
          ? createdAt?.toUtc().toIso8601String()
          : now,
      BankConnectionFields.updatedAt: now,
    };
  }

  static DateTime? _date(Object? value) =>
      value == null ? null : DateTime.parse(value as String).toUtc();
}
