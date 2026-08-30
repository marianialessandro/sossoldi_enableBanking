import 'base_entity.dart';

const String bankConnectionTable = 'bankConnection';

class BankConnectionFields extends BaseEntityFields {
  static String id = BaseEntityFields.getId;
  static String aspspName = 'aspspName';
  static String aspspCountry = 'aspspCountry';
  static String sessionId = 'sessionId';
  static String validUntil = 'validUntil';
  static String status = 'status';
  static String psuType = 'psuType';
  static String createdAt = BaseEntityFields.getCreatedAt;
  static String updatedAt = BaseEntityFields.getUpdatedAt;

  static final List<String> allFields = [
    BaseEntityFields.id,
    aspspName,
    aspspCountry,
    sessionId,
    validUntil,
    status,
    psuType,
    BaseEntityFields.createdAt,
    BaseEntityFields.updatedAt,
  ];
}

enum BankConnectionStatus {
  active,
  expired,
  revoked;

  String get code => switch (this) {
    BankConnectionStatus.active => 'ACTIVE',
    BankConnectionStatus.expired => 'EXPIRED',
    BankConnectionStatus.revoked => 'REVOKED',
  };

  static BankConnectionStatus fromJson(String code) =>
      BankConnectionStatus.values.firstWhere((e) => e.code == code);

  String toJson() => code;
}

class BankConnection extends BaseEntity {
  final String aspspName;
  final String aspspCountry;
  final String sessionId;
  final DateTime validUntil;
  final BankConnectionStatus status;
  final String? psuType;

  const BankConnection({
    super.id,
    required this.aspspName,
    required this.aspspCountry,
    required this.sessionId,
    required this.validUntil,
    required this.status,
    this.psuType,
    super.createdAt,
    super.updatedAt,
  });

  BankConnection copy({
    int? id,
    String? aspspName,
    String? aspspCountry,
    String? sessionId,
    DateTime? validUntil,
    BankConnectionStatus? status,
    String? psuType,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => BankConnection(
    id: id ?? this.id,
    aspspName: aspspName ?? this.aspspName,
    aspspCountry: aspspCountry ?? this.aspspCountry,
    sessionId: sessionId ?? this.sessionId,
    validUntil: validUntil ?? this.validUntil,
    status: status ?? this.status,
    psuType: psuType ?? this.psuType,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  static BankConnection fromJson(Map<String, Object?> json) => BankConnection(
    id: json[BaseEntityFields.id] as int?,
    aspspName: json[BankConnectionFields.aspspName] as String,
    aspspCountry: json[BankConnectionFields.aspspCountry] as String,
    sessionId: json[BankConnectionFields.sessionId] as String,
    validUntil: DateTime.parse(json[BankConnectionFields.validUntil] as String),
    status: BankConnectionStatus.fromJson(
      json[BankConnectionFields.status] as String,
    ),
    psuType: json[BankConnectionFields.psuType] as String?,
    createdAt: json[BaseEntityFields.createdAt] != null
        ? DateTime.parse(json[BaseEntityFields.createdAt] as String)
        : null,
    updatedAt: json[BaseEntityFields.updatedAt] != null
        ? DateTime.parse(json[BaseEntityFields.updatedAt] as String)
        : null,
  );

  Map<String, Object?> toJson({bool update = false}) => {
    BaseEntityFields.id: id,
    BankConnectionFields.aspspName: aspspName,
    BankConnectionFields.aspspCountry: aspspCountry,
    BankConnectionFields.sessionId: sessionId,
    BankConnectionFields.validUntil: validUntil.toUtc().toIso8601String(),
    BankConnectionFields.status: status.toJson(),
    BankConnectionFields.psuType: psuType,
    BaseEntityFields.createdAt: update
        ? createdAt?.toIso8601String()
        : DateTime.now().toIso8601String(),
    BaseEntityFields.updatedAt: DateTime.now().toIso8601String(),
  };
}
