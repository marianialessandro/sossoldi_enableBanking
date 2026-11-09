import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../model/bank_connection.dart';
import '../banking_exception.dart';
import '../storage/banking_secure_storage.dart';
import 'bank_authorization_coordinator.dart';

enum BankSessionRecoveryPhase {
  exchangeStarted,
  outcomeUnknown,
  knownSession,
  cleanupRequired,
}

class BankSessionRecoveryStorageException extends BankingException {
  const BankSessionRecoveryStorageException()
    : super(providerId: 'application', failure: BankingFailure.invalidResponse);
}

/// Contains references only: callback codes, state, credentials and account payloads never enter this journal.
class BankSessionRecoveryRecord {
  final String providerId;
  final String applicationId;
  final String authorizationId;
  final int? reconnectConnectionId;
  final String? remoteConnectionId;
  final BankSessionRecoveryPhase phase;
  final BankConnectionStatus? restoreStatus;
  final DateTime updatedAt;

  const BankSessionRecoveryRecord({
    required this.providerId,
    required this.applicationId,
    required this.authorizationId,
    this.reconnectConnectionId,
    this.remoteConnectionId,
    required this.phase,
    this.restoreStatus,
    required this.updatedAt,
  });

  bool sameAttempt(BankSessionRecoveryRecord other) =>
      providerId == other.providerId &&
      applicationId == other.applicationId &&
      authorizationId == other.authorizationId;
  bool sameVersion(BankSessionRecoveryRecord other) =>
      sameAttempt(other) &&
      reconnectConnectionId == other.reconnectConnectionId &&
      remoteConnectionId == other.remoteConnectionId &&
      restoreStatus == other.restoreStatus &&
      _readPhase == other._readPhase &&
      updatedAt.isAtSameMomentAs(other.updatedAt);
  BankSessionRecoveryPhase get _readPhase =>
      phase == BankSessionRecoveryPhase.exchangeStarted
      ? BankSessionRecoveryPhase.outcomeUnknown
      : phase;

  BankSessionRecoveryRecord copy({
    BankSessionRecoveryPhase? phase,
    String? remoteConnectionId,
    DateTime? updatedAt,
    BankConnectionStatus? restoreStatus,
  }) => BankSessionRecoveryRecord(
    providerId: providerId,
    applicationId: applicationId,
    authorizationId: authorizationId,
    reconnectConnectionId: reconnectConnectionId,
    remoteConnectionId: remoteConnectionId ?? this.remoteConnectionId,
    phase: phase ?? this.phase,
    restoreStatus: restoreStatus ?? this.restoreStatus,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'provider': providerId,
    'application': applicationId,
    'authorization': authorizationId,
    'reconnect': reconnectConnectionId,
    'remote': remoteConnectionId,
    'phase': phase.name,
    if (restoreStatus != null) 'restore_status': restoreStatus!.code,
    'updated': updatedAt.toUtc().toIso8601String(),
  };

  factory BankSessionRecoveryRecord.fromJson(Map<String, dynamic> json) {
    final phase = BankSessionRecoveryPhase.values.byName(
      json['phase'] as String,
    );
    final record = BankSessionRecoveryRecord(
      providerId: json['provider'] as String,
      applicationId: json['application'] as String,
      authorizationId: json['authorization'] as String,
      reconnectConnectionId: json['reconnect'] as int?,
      remoteConnectionId: json['remote'] as String?,
      phase: phase == BankSessionRecoveryPhase.exchangeStarted
          ? BankSessionRecoveryPhase.outcomeUnknown
          : phase,
      restoreStatus: json['restore_status'] == null
          ? null
          : BankConnectionStatus.fromJson(json['restore_status'] as String),
      updatedAt: DateTime.parse(json['updated'] as String).toUtc(),
    );
    if ([
          record.providerId,
          record.applicationId,
          record.authorizationId,
        ].any((value) => value.trim().isEmpty) ||
        (record.remoteConnectionId != null &&
            record.remoteConnectionId!.trim().isEmpty) ||
        ({
              BankSessionRecoveryPhase.knownSession,
              BankSessionRecoveryPhase.cleanupRequired,
            }.contains(record.phase) &&
            record.remoteConnectionId == null)) {
      throw const FormatException();
    }
    return record;
  }
}

abstract interface class BankSessionRecoveryStore {
  Future<List<BankSessionRecoveryRecord>> read();
  Future<bool> upsert(
    BankSessionRecoveryRecord record, {
    BankSessionRecoveryRecord? expected,
  });
  Future<bool> removeIfCurrent(BankSessionRecoveryRecord expected);
}

class BankSessionOutcomeUnknownException extends BankingException {
  const BankSessionOutcomeUnknownException()
    : super(providerId: 'application', failure: BankingFailure.rejected);
}

class BankSessionRecoveryReport {
  final int unknown;
  final int cleanupConfirmed;
  final int retryFailed;
  final int ownerUnavailable;
  final int notPersisted;
  const BankSessionRecoveryReport({
    this.unknown = 0,
    this.cleanupConfirmed = 0,
    this.retryFailed = 0,
    this.ownerUnavailable = 0,
    this.notPersisted = 0,
  });
  bool get needsAttention =>
      unknown + retryFailed + ownerUnavailable + notPersisted > 0;
}

class SecureBankSessionRecoveryStore implements BankSessionRecoveryStore {
  static const _key = 'bank_session_recovery_v1';
  final FlutterSecureStorage _storage;
  const SecureBankSessionRecoveryStore({FlutterSecureStorage? storage})
    : _storage = storage ?? bankingSecureStorage;
  BankAuthorizationCoordinator get _coordinator =>
      BankAuthorizationCoordinator.forScope(_storage);

  @override
  Future<List<BankSessionRecoveryRecord>> read() async {
    try {
      final encoded = await _storage.read(key: _key);
      if (encoded == null) return [];
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      if (json['version'] != 1) throw const FormatException();
      return (json['records'] as List)
          .map(
            (value) => BankSessionRecoveryRecord.fromJson(
              value as Map<String, dynamic>,
            ),
          )
          .toList();
    } catch (_) {
      throw const BankSessionRecoveryStorageException();
    }
  }

  Future<void> _write(List<BankSessionRecoveryRecord> records) async {
    try {
      if (records.isEmpty) {
        await _storage.delete(key: _key);
      } else {
        await _storage.write(
          key: _key,
          value: jsonEncode({
            'version': 1,
            'records': records.map((record) => record.toJson()).toList(),
          }),
        );
      }
    } catch (_) {
      throw const BankSessionRecoveryStorageException();
    }
  }

  @override
  Future<bool> upsert(
    BankSessionRecoveryRecord record, {
    BankSessionRecoveryRecord? expected,
  }) => _coordinator.cleanup(() async {
    final records = await read();
    final index = records.indexWhere((value) => value.sameAttempt(record));
    if (expected == null) {
      if (index >= 0) return false;
    } else if (index < 0 || !records[index].sameVersion(expected)) {
      return false;
    }
    if (index < 0) {
      records.add(record);
    } else {
      records[index] = record;
    }
    await _write(records);
    return true;
  });

  @override
  Future<bool> removeIfCurrent(BankSessionRecoveryRecord expected) =>
      _coordinator.cleanup(() async {
        final records = await read();
        final index = records.indexWhere(
          (value) => value.sameVersion(expected),
        );
        if (index < 0) return false;
        records.removeAt(index);
        await _write(records);
        return true;
      });
}
