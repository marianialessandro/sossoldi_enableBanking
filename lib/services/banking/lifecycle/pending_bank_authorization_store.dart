import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../banking_exception.dart';
import '../storage/banking_secure_storage.dart';
import 'pending_bank_authorization.dart';
import 'bank_authorization_coordinator.dart';

// Preserve the storage key used by existing pending authorizations.
const _kPendingAuthorizationKey = 'eb_pending_authorization_v1';

abstract class PendingBankAuthorizationStore {
  Future<void> save(PendingBankAuthorization pending);

  Future<PendingBankAuthorization?> read();

  Future<void> clear();
}

extension PendingBankAuthorizationCoordination
    on PendingBankAuthorizationStore {
  Future<bool> clearIfCurrent(PendingBankAuthorization expected) =>
      coordinator.commit(() async {
        final current = await read();
        if (current == null ||
            current.providerId != expected.providerId ||
            current.applicationId != expected.applicationId ||
            current.state != expected.state ||
            current.authorizationId != expected.authorizationId ||
            current.stagedConnectionId != expected.stagedConnectionId ||
            current.reconnectConnectionId != expected.reconnectConnectionId) {
          return false;
        }
        await clear();
        return true;
      });

  BankAuthorizationCoordinator get coordinator {
    final store = this;
    return BankAuthorizationCoordinator.forScope(
      store is BankAuthorizationScope
          ? (store as BankAuthorizationScope).authorizationScope
          : store,
    );
  }
}

class SecurePendingBankAuthorizationStore
    implements
        PendingBankAuthorizationStore,
        BankAuthorizationScope,
        BankAuthorizationCleanupStore {
  final FlutterSecureStorage _storage;
  final FlutterSecureStorage _legacyStorage;

  @override
  Object get authorizationScope => _storage;

  static const _cleanupKey = 'eb_obsolete_connections_v1';

  @override
  Future<List<ObsoleteBankConnection>> readObsoleteConnections() async {
    final encoded = await _storage.read(key: _cleanupKey);
    if (encoded == null) return [];
    try {
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      if (json['version'] != 1) throw const FormatException();
      return (json['connections'] as List)
          .map(
            (value) =>
                ObsoleteBankConnection.fromJson(value as Map<String, dynamic>),
          )
          .toList();
    } catch (_) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.invalidResponse,
      );
    }
  }

  Future<void> _writeObsoleteConnections(List<ObsoleteBankConnection> values) =>
      _storage.write(
        key: _cleanupKey,
        value: jsonEncode({
          'version': 1,
          'connections': values.map((value) => value.toJson()).toList(),
        }),
      );

  @override
  Future<void> saveObsoleteConnection(ObsoleteBankConnection connection) =>
      coordinator.cleanup(() async {
        final values = await readObsoleteConnections();
        if (!values.any((value) => value.sameConnection(connection))) {
          await _writeObsoleteConnections([...values, connection]);
        }
      });

  @override
  Future<void> removeObsoleteConnection(ObsoleteBankConnection connection) =>
      coordinator.cleanup(() async {
        final values = await readObsoleteConnections();
        await _writeObsoleteConnections(
          values.where((value) => !value.sameConnection(connection)).toList(),
        );
      });

  const SecurePendingBankAuthorizationStore({FlutterSecureStorage? storage})
    : _storage = storage ?? bankingSecureStorage,
      _legacyStorage = storage ?? const FlutterSecureStorage();

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
    } on BankingException {
      rethrow;
    } catch (error) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.invalidResponse,
      );
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _kPendingAuthorizationKey);
    // Older iOS entries retain their original accessibility class, so delete through both configurations.
    await _legacyStorage.delete(key: _kPendingAuthorizationKey);
  }
}
