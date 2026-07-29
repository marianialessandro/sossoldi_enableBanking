import 'base_entity.dart';

const String bankConnectionTable = 'bankConnection';

/// SQL identifiers for [bankConnectionTable], added in migration 0008. The
/// full `BankConnection` entity (status enum, `copy`/`fromJson`/`toJson`)
/// is added in a later step alongside its repository.
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
