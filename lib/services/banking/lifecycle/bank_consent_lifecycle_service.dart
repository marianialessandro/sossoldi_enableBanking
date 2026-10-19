import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:url_launcher/url_launcher.dart';

import '../../../model/bank_account.dart';
import '../../../model/bank_account_link.dart';
import '../../../model/bank_connection.dart';
import '../../database/repositories/bank_connection_repository.dart';
import '../bank_authorization_context.dart';
import '../bank_consent_service.dart';
import '../bank_institution.dart';
import '../bank_institution_directory.dart';
import '../banking_account.dart';
import '../banking_authorization.dart';
import '../banking_connection.dart';
import '../banking_exception.dart';
import '../banking_reference.dart';
import '../sync/bank_money.dart';
import 'bank_authorization_callback.dart';
import 'bank_authorization_coordinator.dart';
import 'bank_authorization_result.dart';
import 'bank_session_recovery_store.dart';
import 'banking_platform_support.dart';
import 'pending_bank_authorization.dart';
import 'pending_bank_authorization_store.dart';

const _kDefaultConsentValidity = Duration(days: 90);
const _kAuthorizationLifetime = Duration(minutes: 15);

class BankConsentLifecycleService {
  final BankConsentService _consent;
  final BankInstitutionDirectory _institutions;
  final BankAuthorizationContextReader _readContext;
  final PendingBankAuthorizationStore _pendingStore;
  final BankConnectionRepository _connections;
  final DateTime Function() _clock;
  final bool Function() _callbackSupported;
  final Random _random;
  final BankSessionRecoveryStore? _recoveryStore;
  Future<BankSessionRecoveryReport>? _recovery;

  final int Function()? _credentialRevision;
  final ObsoleteBankConnectionHandler? _cleanupObsoleteConnection;
  BankAuthorizationCoordinator get _coordinator => _pendingStore.coordinator;

  BankConsentLifecycleService({
    required BankConsentService consent,
    required BankInstitutionDirectory institutions,
    required BankAuthorizationContextReader readContext,
    required PendingBankAuthorizationStore pendingStore,
    required BankConnectionRepository connections,
    DateTime Function()? clock,
    bool Function()? callbackSupported,
    Random? random,
    int Function()? credentialRevision,
    ObsoleteBankConnectionHandler? cleanupObsoleteConnection,
    BankSessionRecoveryStore? recoveryStore,
  }) : _recoveryStore = recoveryStore,
       _consent = consent,
       _institutions = institutions,
       _readContext = readContext,
       _pendingStore = pendingStore,
       _connections = connections,
       _clock = clock ?? DateTime.now,
       _callbackSupported =
           callbackSupported ?? BankingPlatformSupport.supportsCallback,
       _random = random ?? Random.secure(),
       _credentialRevision = credentialRevision,
       _cleanupObsoleteConnection = cleanupObsoleteConnection;

  Future<AuthorizationAttempt> startAuthorization(
    BankInstitution selectedBankInstitution, {
    int? reconnectConnectionId,
  }) {
    final revision = _coordinator.revision;
    final credentials = _credentialRevision?.call();
    final key = (
      selectedBankInstitution.providerId,
      selectedBankInstitution.id,
      selectedBankInstitution.name,
      selectedBankInstitution.country,
      reconnectConnectionId,
      credentials,
      revision,
    );
    return _coordinator.start(
      key,
      () => _startAuthorization(
        selectedBankInstitution,
        reconnectConnectionId,
        revision,
        credentials,
      ),
      readContextKey: () async {
        final context = await _readContext();
        await _checkCurrent(revision, credentials, context);
        _assertCurrent(revision, credentials);
        return (context.providerId, context.applicationId, context.redirectUri);
      },
    );
  }

  bool _isCurrent(int revision, int? credentials) =>
      revision == _coordinator.revision &&
      credentials == _credentialRevision?.call();

  void _assertCurrent(int revision, int? credentials) {
    if (!_isCurrent(revision, credentials)) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
  }

  Future<void> _checkCurrent(
    int revision,
    int? credentials, [
    BankAuthorizationContext? context,
    PendingBankAuthorization? pending,
  ]) async {
    void check() {
      if (!_isCurrent(revision, credentials)) {
        throw const BankingException(
          providerId: 'application',
          failure: BankingFailure.rejected,
        );
      }
    }

    check();
    if (context != null) {
      final current = await _readContext();
      check();
      if (current.providerId != context.providerId ||
          current.applicationId != context.applicationId ||
          current.redirectUri != context.redirectUri) {
        throw const BankingException(
          providerId: 'application',
          failure: BankingFailure.authentication,
        );
      }
    }
    if (pending != null) {
      final current = await _pendingStore.read();
      check();
      if (current?.state != pending.state ||
          current?.authorizationId != pending.authorizationId ||
          current?.applicationId != pending.applicationId ||
          current?.providerId != pending.providerId) {
        throw const BankingException(
          providerId: 'application',
          failure: BankingFailure.rejected,
        );
      }
      if (_credentialRevision == null && context != null) {
        final latest = await _readContext();
        check();
        if (latest.providerId != context.providerId ||
            latest.applicationId != context.applicationId ||
            latest.redirectUri != context.redirectUri) {
          throw const BankingException(
            providerId: 'application',
            failure: BankingFailure.authentication,
          );
        }
      }
    }
  }

  Future<void> _clearOwnedPending(
    PendingBankAuthorization pending, {
    int? allowedStagedConnectionId,
  }) => _coordinator.commit(() async {
    final current = await _pendingStore.read();
    if (current?.state == pending.state &&
        current?.authorizationId == pending.authorizationId &&
        current?.providerId == pending.providerId &&
        current?.applicationId == pending.applicationId &&
        (current?.stagedConnectionId == pending.stagedConnectionId ||
            (allowedStagedConnectionId != null &&
                current?.stagedConnectionId == allowedStagedConnectionId))) {
      await _pendingStore.clear();
    }
  });

  Future<void> _savePending(
    PendingBankAuthorization pending,
    int revision,
    int? credentials,
    BankAuthorizationContext context,
  ) => _coordinator.commit(() async {
    await _checkCurrent(revision, credentials, context);
    _assertCurrent(revision, credentials);
    try {
      await _pendingStore.save(pending);
      await _checkCurrent(revision, credentials, context, pending);
      _assertCurrent(revision, credentials);
    } catch (_) {
      final current = await _pendingStore.read();
      if (current?.state == pending.state &&
          current?.providerId == pending.providerId &&
          current?.applicationId == pending.applicationId &&
          current?.authorizationId == pending.authorizationId) {
        await _pendingStore.clear();
      }
      rethrow;
    }
  });

  Future<AuthorizationAttempt> _startAuthorization(
    BankInstitution selectedBankInstitution,
    int? reconnectConnectionId,
    int revision,
    int? credentials,
  ) async {
    if (!_callbackSupported()) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    final config = await _readContext();
    await _checkCurrent(revision, credentials, config);
    _assertCurrent(revision, credentials);
    if (selectedBankInstitution.providerId != config.providerId) {
      throw BankingException(
        providerId: config.providerId,
        failure: BankingFailure.rejected,
      );
    }
    final existingPending = await _coordinator.commit(
      () => _pendingStore.read(),
    );
    await _checkCurrent(revision, credentials, config);
    _assertCurrent(revision, credentials);
    if (existingPending != null) {
      if (!existingPending.expiresAt.isAfter(_clock().toUtc())) {
        await _clearOwnedPending(existingPending);
        await _checkCurrent(revision, credentials, config);
        _assertCurrent(revision, credentials);
      } else if (existingPending.providerId == config.providerId &&
          existingPending.applicationId == config.applicationId &&
          existingPending.redirectUri == config.redirectUri &&
          existingPending.institutionName == selectedBankInstitution.name &&
          existingPending.institutionCountry ==
              selectedBankInstitution.country &&
          existingPending.reconnectConnectionId == reconnectConnectionId) {
        return AuthorizationAttempt(
          url: Uri.parse(existingPending.authorizationUrl),
          consentValidUntil: existingPending.consentValidUntil,
        );
      } else {
        throw const BankingException(
          providerId: 'application',
          failure: BankingFailure.rejected,
        );
      }
    }

    final institution = reconnectConnectionId == null
        ? selectedBankInstitution
        : await _freshReconnectBankInstitution(
            selectedBankInstitution,
            reconnectConnectionId,
            config.applicationId,
          );
    await _checkCurrent(revision, credentials, config);
    _assertCurrent(revision, credentials);
    if (!institution.customerTypes.contains(BankingCustomerType.personal)) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    final maximum = institution.maximumConsentDuration;
    final validity = maximum == null
        ? _kDefaultConsentValidity
        : Duration(
            seconds: min(
              _kDefaultConsentValidity.inSeconds,
              max(0, maximum.inSeconds),
            ),
          );
    if (validity == Duration.zero) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.invalidResponse,
      );
    }

    final now = _clock().toUtc();
    final state = _newState();
    final consentValidUntil = now.add(validity);
    final authorization = await _consent.startAuthorization(
      BankingAuthorizationRequest(
        institution: institution,
        state: state,
        validUntil: consentValidUntil,
        redirectUri: Uri.parse(config.redirectUri),
      ),
    );
    await _checkCurrent(revision, credentials, config);
    _assertCurrent(revision, credentials);
    final authorizationUri = authorization.uri;
    if (authorization.providerId != config.providerId ||
        authorization.authorizationId.trim().isEmpty ||
        authorizationUri.host.isEmpty ||
        authorizationUri.userInfo.isNotEmpty ||
        !authorizationUri.hasScheme ||
        authorizationUri.scheme != 'https') {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.invalidResponse,
      );
    }
    await _savePending(
      PendingBankAuthorization(
        providerId: config.providerId,
        state: state,
        authorizationId: authorization.authorizationId,
        authorizationUrl: authorization.uri.toString(),
        applicationId: config.applicationId,
        institutionName: institution.name,
        institutionCountry: institution.country,
        redirectUri: config.redirectUri,
        expiresAt: now.add(_kAuthorizationLifetime),
        consentValidUntil: consentValidUntil,
        reconnectConnectionId: reconnectConnectionId,
      ),
      revision,
      credentials,
      config,
    );
    await _checkCurrent(revision, credentials, config);
    _assertCurrent(revision, credentials);
    return AuthorizationAttempt(
      url: authorizationUri,
      consentValidUntil: consentValidUntil,
    );
  }

  Future<AuthorizationLaunchResult> launchAuthorization(
    Uri url, {
    AuthorizationUrlLauncher? launcher,
  }) async {
    final opened = await (launcher ?? _launch)(url);
    return AuthorizationLaunchResult(url: url, opened: opened);
  }

  Future<void> cancelAuthorization() {
    _coordinator.invalidate();
    return _coordinator.commit(() => _pendingStore.clear());
  }

  Future<bool> clearExpiredAuthorization() => _coordinator.commit(() async {
    final pending = await _pendingStore.read();
    if (pending == null || pending.expiresAt.isAfter(_clock().toUtc())) {
      return false;
    }
    _coordinator.invalidate();
    await _pendingStore.clear();
    return true;
  });

  Future<StagedBankConnection> completeCallback(
    BankAuthorizationCallback callback,
  ) {
    final revision = _coordinator.revision;
    final credentials = _credentialRevision?.call();
    return _coordinator.completeCallback((
      callback.state,
      callback.code,
      callback.error,
      revision,
      credentials,
    ), () => _completeCallback(callback, revision, credentials));
  }

  Future<BankCallbackDisposition> handleCallback(
    BankAuthorizationCallback callback, {
    Future<void> Function(StagedBankConnection result)? onStaged,
    Future<void> Function(Object error)? onError,
  }) async {
    final revision = _coordinator.revision;
    final credentials = _credentialRevision?.call();
    try {
      final staged = await completeCallback(callback);
      await _checkCurrent(revision, credentials);
      _assertCurrent(revision, credentials);
      final context = await _readContext();
      await _checkCurrent(revision, credentials, context);
      _assertCurrent(revision, credentials);
      if (staged.connection.providerId != context.providerId ||
          staged.connection.applicationId != context.applicationId) {
        throw const BankingException(
          providerId: 'application',
          failure: BankingFailure.authentication,
        );
      }
      if (onStaged != null) await onStaged(staged);
      return BankCallbackDisposition.terminal;
    } on BankingException catch (error) {
      if (onError != null) await onError(error);
      return error.isRetryable
          ? BankCallbackDisposition.retryable
          : BankCallbackDisposition.terminal;
    } catch (error) {
      if (onError != null) await onError(error);
      return BankCallbackDisposition.retryable;
    }
  }

  Future<StagedBankConnection> _completeCallback(
    BankAuthorizationCallback callback,
    int revision,
    int? credentials,
  ) async {
    await _checkCurrent(revision, credentials);
    _assertCurrent(revision, credentials);
    final pending = await _pendingStore.read();
    await _checkCurrent(revision, credentials);
    _assertCurrent(revision, credentials);
    if (pending == null) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    if (callback.state == null || callback.state != pending.state) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    if (!pending.expiresAt.isAfter(_clock().toUtc())) {
      await _clearOwnedPending(pending);
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.connectionExpired,
      );
    }
    if (callback.error != null) {
      await _clearOwnedPending(pending);
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    if (callback.code == null || callback.code!.trim().isEmpty) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }

    final context = await _readContext();
    await _checkCurrent(revision, credentials, context, pending);
    _assertCurrent(revision, credentials);
    if (context.providerId != pending.providerId ||
        context.applicationId != pending.applicationId ||
        context.redirectUri != pending.redirectUri) {
      throw BankingException(
        providerId: pending.providerId,
        failure: BankingFailure.authentication,
      );
    }

    if (pending.stagedConnectionId case final id?) {
      final connection = await _connections.selectById(id);
      await _checkCurrent(revision, credentials, context, pending);
      _assertCurrent(revision, credentials);
      if (!_pendingOwns(pending, connection) ||
          connection.pendingRemoteConnectionId == null ||
          !{
            BankConnectionStatus.awaitingImport,
            BankConnectionStatus.active,
            BankConnectionStatus.expired,
            BankConnectionStatus.reauthRequired,
          }.contains(connection.status)) {
        throw const BankingException(
          providerId: 'application',
          failure: BankingFailure.rejected,
        );
      }
      return StagedBankConnection(connection: connection);
    }
    final durable = await _connections.findByPendingAuthorizationId(
      pending.authorizationId,
      providerId: pending.providerId,
    );
    await _checkCurrent(revision, credentials, context, pending);
    _assertCurrent(revision, credentials);
    if (durable != null) {
      if (!_pendingOwns(pending, durable)) {
        throw const BankingException(
          providerId: 'application',
          failure: BankingFailure.rejected,
        );
      }
      await _savePending(
        pending.copy(
          stagedConnectionId: durable.id,
          phase: PendingAuthorizationPhase.connectionStaged,
        ),
        revision,
        credentials,
        context,
      );
      await _checkCurrent(revision, credentials, context, pending);
      _assertCurrent(revision, credentials);
      return StagedBankConnection(connection: durable);
    }

    final journal = _recoveryStore;
    BankSessionRecoveryRecord? receipt;
    if (journal != null) {
      final existing = (await journal.read()).where(
        (record) =>
            record.providerId == pending.providerId &&
            record.applicationId == pending.applicationId &&
            record.authorizationId == pending.authorizationId,
      );
      if (existing.isNotEmpty) throw const BankSessionOutcomeUnknownException();
      receipt = BankSessionRecoveryRecord(
        providerId: pending.providerId,
        applicationId: pending.applicationId,
        authorizationId: pending.authorizationId,
        reconnectConnectionId: pending.reconnectConnectionId,
        phase: BankSessionRecoveryPhase.exchangeStarted,
        updatedAt: _clock().toUtc(),
      );
      if (!await journal.upsert(receipt)) {
        throw const BankSessionOutcomeUnknownException();
      }
    }
    BankingConnectionReference? captured;
    BankConnection? committed;
    try {
      await _checkCurrent(revision, credentials, context, pending);
      Future<void> onReference(BankingConnectionReference reference) async {
        captured = reference;
        if (journal != null) {
          final known = receipt!.copy(
            phase: BankSessionRecoveryPhase.knownSession,
            remoteConnectionId: reference.remoteId,
            updatedAt: _clock().toUtc(),
          );
          if (!await journal.upsert(known, expected: receipt)) {
            throw const BankSessionRecoveryStorageException();
          }
          receipt = known;
        }
      }

      final consent = _consent;
      final result = consent is BankConnectionReceiptSource
          ? await (consent as BankConnectionReceiptSource)
                .createConnectionWithReceipt(callback.code!, onReference)
          : await consent.createConnection(callback.code!);
      if (captured == null) await onReference(result.connection.reference);
      await _checkCurrent(revision, credentials, context, pending);
      _assertCurrent(revision, credentials);
      if (result.connection.reference.providerId != pending.providerId ||
          result.connection.institution.providerId != pending.providerId ||
          result.connection.reference.remoteId.trim().isEmpty ||
          result.connection.status != BankingConnectionStatus.active ||
          !result.connection.validUntil.isAfter(_clock().toUtc()) ||
          !result.connection.institution.customerTypes.contains(
            BankingCustomerType.personal,
          ) ||
          result.connection.institution.name != pending.institutionName ||
          result.connection.institution.country != pending.institutionCountry) {
        throw const BankingException(
          providerId: 'application',
          failure: BankingFailure.invalidResponse,
        );
      }
      final connection = await _coordinator.commit(() async {
        await _checkCurrent(revision, credentials, context, pending);
        _assertCurrent(revision, credentials);
        BankConnection? staged;
        try {
          staged = await _connections.stageConnection(
            providerId: pending.providerId,
            authorizationId: pending.authorizationId,
            applicationId: pending.applicationId,
            institutionName: result.connection.institution.name,
            institutionCountry: result.connection.institution.country,
            remoteConnectionId: result.connection.reference.remoteId,
            validUntil: result.connection.validUntil,
            psuType: 'personal',
            reconnectConnectionId: pending.reconnectConnectionId,
            isAuthorizationCurrent: () => _isCurrent(revision, credentials),
          );
          committed = staged;
          await _checkCurrent(revision, credentials, context, pending);
          _assertCurrent(revision, credentials);
          await _pendingStore.save(
            pending.copy(
              stagedConnectionId: staged.id,
              phase: PendingAuthorizationPhase.connectionStaged,
            ),
          );
          await _checkCurrent(revision, credentials, context, pending);
          _assertCurrent(revision, credentials);
          return staged;
        } catch (_) {
          if (staged?.id case final id?) {
            await _connections.discardAuthorizationStaging(
              id,
              pending.authorizationId,
              result.connection.reference.remoteId,
              expectedStaging: staged,
            );
          }
          rethrow;
        }
      });
      committed = connection;
      await _checkCurrent(revision, credentials, context, pending);
      _assertCurrent(revision, credentials);
      return StagedBankConnection(
        connection: connection,
        createdConnection: result,
      );
    } catch (_) {
      if (captured == null) {
        if (journal != null) throw const BankSessionOutcomeUnknownException();
        rethrow;
      }
      throw await _obsoleteConnection(
        pending,
        captured!,
        revision,
        credentials,
        context,
        discardLocal: () async {
          if (committed?.id case final id?) {
            await _connections.discardAuthorizationStaging(
              id,
              pending.authorizationId,
              captured!.remoteId,
              expectedStaging: committed,
            );
          }
          await _clearOwnedPending(
            pending,
            allowedStagedConnectionId: committed?.id,
          );
        },
        receipt: receipt,
      );
    }
  }

  Future<ObsoleteBankAuthorizationException> _obsoleteConnection(
    PendingBankAuthorization pending,
    BankingConnectionReference result,
    int revision,
    int? credentials,
    BankAuthorizationContext context, {
    required Future<void> Function() discardLocal,
    BankSessionRecoveryRecord? receipt,
  }) async {
    final reference = ObsoleteBankConnection(
      providerId: result.providerId,
      applicationId: pending.applicationId,
      authorizationId: pending.authorizationId,
      remoteConnectionId: result.remoteId,
      attemptRevision: revision,
      reason: 'authorization_invalidated',
    );
    final unresolved = _coordinator.unresolvedConnections;
    if (!unresolved.any((value) => value.sameConnection(reference))) {
      unresolved.add(reference);
    }
    final store = _pendingStore;
    var journalPersisted = false;
    var legacyPersisted = false;
    var confirmed = false;
    final journal = _recoveryStore;
    if (journal != null && receipt != null) {
      try {
        final required = receipt.copy(
          phase: BankSessionRecoveryPhase.cleanupRequired,
          remoteConnectionId: result.remoteId,
          updatedAt: _clock().toUtc(),
        );
        if (await journal.upsert(required, expected: receipt)) {
          receipt = required;
        }
        journalPersisted = (await journal.read()).any(
          (record) =>
              record.sameAttempt(receipt!) &&
              record.remoteConnectionId == result.remoteId,
        );
      } catch (_) {}
    }
    if (store is BankAuthorizationCleanupStore) {
      try {
        await (store as BankAuthorizationCleanupStore).saveObsoleteConnection(
          reference,
        );
        legacyPersisted = true;
      } catch (_) {}
    }
    var localCleanupConfirmed = true;
    try {
      await discardLocal();
    } catch (_) {
      localCleanupConfirmed = false;
    }
    try {
      final handler = _cleanupObsoleteConnection;
      if (handler != null) {
        confirmed = await handler(reference);
      } else {
        final current = await _readContext();
        if (reference.providerId == context.providerId &&
            reference.remoteConnectionId.isNotEmpty &&
            current.providerId == context.providerId &&
            current.applicationId == context.applicationId &&
            credentials == _credentialRevision?.call()) {
          await _consent.revokeConnection(
            BankingConnectionReference(
              providerId: reference.providerId,
              remoteId: reference.remoteConnectionId,
            ),
          );
          confirmed = true;
        }
      }
    } on BankingException catch (error) {
      confirmed = error.confirmsMissingConnection;
    } catch (_) {}
    if (confirmed) {
      if (store is BankAuthorizationCleanupStore) {
        try {
          await (store as BankAuthorizationCleanupStore)
              .removeObsoleteConnection(reference);
          legacyPersisted = false;
        } catch (_) {}
      }
      if (journal != null && receipt != null) {
        try {
          if (await journal.removeIfCurrent(receipt)) journalPersisted = false;
        } catch (_) {}
      }
      unresolved.removeWhere((value) => value.sameConnection(reference));
    }
    return ObsoleteBankAuthorizationException(
      connection: reference,
      cleanupConfirmed: confirmed,
      referencePersisted: journalPersisted || legacyPersisted,
      localCleanupConfirmed: localCleanupConfirmed,
    );
  }

  Future<BankSessionRecoveryReport> recoverSessions() {
    final existing = _recovery;
    if (existing != null) return existing;
    final operation = _coordinator.callback(_recoverSessions);
    _recovery = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_recovery, operation)) _recovery = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_recovery, operation)) _recovery = null;
        },
      ),
    );
    return operation;
  }

  Future<BankSessionRecoveryReport> _recoverSessions() async {
    var unknown = 0;
    var confirmed = 0;
    var failed = 0;
    var unavailable = 0;
    var notPersisted = 0;
    final journal = _recoveryStore;
    final records = await journal?.read() ?? <BankSessionRecoveryRecord>[];
    final legacy = _pendingStore;
    final legacyRecords = legacy is BankAuthorizationCleanupStore
        ? await (legacy as BankAuthorizationCleanupStore)
              .readObsoleteConnections()
        : <ObsoleteBankConnection>[];
    final obligations = <ObsoleteBankConnection>[...legacyRecords];
    for (final reference in _coordinator.unresolvedConnections) {
      if (!obligations.any((item) => item.sameConnection(reference))) {
        obligations.add(reference);
      }
    }
    for (final record in records) {
      if (record.remoteConnectionId == null) {
        if (!obligations.any(
          (item) =>
              item.providerId == record.providerId &&
              item.applicationId == record.applicationId &&
              item.authorizationId == record.authorizationId,
        )) {
          unknown++;
        }
        continue;
      }
      final reference = ObsoleteBankConnection(
        providerId: record.providerId,
        applicationId: record.applicationId,
        authorizationId: record.authorizationId,
        remoteConnectionId: record.remoteConnectionId!,
        attemptRevision: 0,
        reason: 'session_recovery',
      );
      if (!obligations.any((item) => item.sameConnection(reference))) {
        obligations.add(reference);
      }
    }
    for (final reference in obligations) {
      final matching = records
          .where(
            (record) =>
                record.providerId == reference.providerId &&
                record.applicationId == reference.applicationId &&
                (record.remoteConnectionId == reference.remoteConnectionId ||
                    (record.remoteConnectionId == null &&
                        record.authorizationId == reference.authorizationId)),
          )
          .toList();
      final persisted =
          matching.any((record) => record.remoteConnectionId != null) ||
          legacyRecords.any((item) => item.sameConnection(reference));
      BankConnection? claimed;
      BankConnectionStatus? restoreStatus;
      final decision = await _coordinator.commit(() async {
        final connections = (await _connections.selectAll())
            .where(
              (connection) =>
                  connection.providerId == reference.providerId &&
                  connection.applicationId == reference.applicationId,
            )
            .toList();
        Future<String> retain() async {
          for (final record in matching) {
            await journal!.removeIfCurrent(record);
          }
          if (legacy is BankAuthorizationCleanupStore) {
            await (legacy as BankAuthorizationCleanupStore)
                .removeObsoleteConnection(reference);
          }
          _coordinator.unresolvedConnections.removeWhere(
            (item) => item.sameConnection(reference),
          );
          return 'retained';
        }

        if (connections.any(
          (connection) =>
              connection.remoteConnectionId == reference.remoteConnectionId &&
              connection.status != BankConnectionStatus.revocationPending,
        )) {
          return retain();
        }
        final staged = connections.where(
          (connection) =>
              connection.pendingRemoteConnectionId ==
              reference.remoteConnectionId,
        );
        BankAuthorizationContext context;
        try {
          context = await _readContext();
        } catch (_) {
          return 'owner';
        }
        if (context.providerId != reference.providerId ||
            context.applicationId != reference.applicationId) {
          return 'owner';
        }
        if (staged.isEmpty) return 'cleanup';
        var connection = staged.first;
        final pending = await _pendingStore.read();
        // Activation may have completed while secure storage was being read.
        final latest = await _connections.findById(connection.id!);
        if (latest == null || !latest.sameLifecycle(connection)) return 'stale';
        connection = latest;
        if (matching.any(
              (record) =>
                  record.phase != BankSessionRecoveryPhase.cleanupRequired,
            ) &&
            pending != null &&
            _pendingOwns(pending, connection) &&
            connection.pendingAuthorizationId == reference.authorizationId &&
            {
              BankConnectionStatus.awaitingImport,
              BankConnectionStatus.active,
              BankConnectionStatus.expired,
              BankConnectionStatus.reauthRequired,
            }.contains(connection.status)) {
          await _pendingStore.save(
            pending.copy(
              stagedConnectionId: connection.id,
              phase: PendingAuthorizationPhase.connectionStaged,
            ),
          );
          return retain();
        }
        // A previous cleanup claim must not become the status restored after a restart.
        final savedStatuses = matching
            .map((record) => record.restoreStatus)
            .whereType<BankConnectionStatus>()
            .toSet();
        if (savedStatuses.length > 1) {
          throw const BankSessionRecoveryStorageException();
        }
        restoreStatus =
            connection.status == BankConnectionStatus.revocationPending &&
                savedStatuses.isNotEmpty
            ? savedStatuses.single
            : connection.status;
        // Persist before SQL so interruption immediately after the claim retains the original status, including for a legacy-only obligation.
        if (journal == null) return 'persistence';
        final previous = matching
            .where(
              (record) => record.authorizationId == reference.authorizationId,
            )
            .firstOrNull;
        final recovery =
            (previous ??
                    BankSessionRecoveryRecord(
                      providerId: reference.providerId,
                      applicationId: reference.applicationId,
                      authorizationId: reference.authorizationId,
                      remoteConnectionId: reference.remoteConnectionId,
                      phase: BankSessionRecoveryPhase.cleanupRequired,
                      updatedAt: _clock().toUtc(),
                    ))
                .copy(
                  phase: BankSessionRecoveryPhase.cleanupRequired,
                  remoteConnectionId: reference.remoteConnectionId,
                  restoreStatus: restoreStatus,
                  updatedAt: _clock().toUtc(),
                );
        if (!await journal.upsert(recovery, expected: previous)) return 'stale';
        if (previous != null) matching.remove(previous);
        matching.add(recovery);
        claimed = await _connections.markStatusIfCurrent(
          connection,
          BankConnectionStatus.revocationPending,
          clock: _clock,
        );
        return claimed == null ? 'stale' : 'cleanup';
      });
      if (decision == 'stale') {
        failed++;
        if (!persisted) notPersisted++;
        continue;
      }
      if (decision == 'persistence') {
        failed++;
        if (!persisted) notPersisted++;
        continue;
      }
      if (decision == 'owner') {
        unavailable++;
        if (!persisted) notPersisted++;
        continue;
      }
      if (decision == 'retained') continue;
      final credentials = _credentialRevision?.call();
      var deleted = false;
      try {
        final handler = _cleanupObsoleteConnection;
        if (handler != null) {
          deleted = await handler(reference);
        } else {
          final current = await _readContext();
          if (current.providerId == reference.providerId &&
              current.applicationId == reference.applicationId &&
              credentials == _credentialRevision?.call()) {
            await _consent.revokeConnection(
              BankingConnectionReference(
                providerId: reference.providerId,
                remoteId: reference.remoteConnectionId,
              ),
            );
            deleted = true;
          }
        }
      } on BankingException catch (error) {
        deleted = error.confirmsMissingConnection;
      } catch (_) {}
      if (!deleted) {
        failed++;
        if (!persisted) notPersisted++;
        continue;
      }
      try {
        if (claimed != null) {
          if (claimed!.remoteConnectionId == null) {
            await _connections.failStagedConnectionIfCurrent(
              claimed!,
              BankConnectionStatus.revoked,
              clock: _clock,
            );
          } else {
            await _connections.discardStagedConnectionIfCurrent(
              claimed!,
              restoreStatus: restoreStatus,
              clock: _clock,
            );
          }
        }
        for (final record in matching) {
          await journal!.removeIfCurrent(record);
        }
        if (legacy is BankAuthorizationCleanupStore) {
          await (legacy as BankAuthorizationCleanupStore)
              .removeObsoleteConnection(reference);
        }
        _coordinator.unresolvedConnections.removeWhere(
          (item) => item.sameConnection(reference),
        );
        confirmed++;
      } catch (_) {
        failed++;
      }
    }
    return BankSessionRecoveryReport(
      unknown: unknown,
      cleanupConfirmed: confirmed,
      retryFailed: failed,
      ownerUnavailable: unavailable,
      notPersisted: notPersisted,
    );
  }

  Future<BankConnection> activateConnection(
    int connectionId,
    List<({BankingAccount remote, BankAccount? newAccount})> selections, {
    BankConnection? expectedStaging,
  }) async {
    if (expectedStaging == null || expectedStaging.id != connectionId) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    final revision = _coordinator.revision;
    final credentials = _credentialRevision?.call();
    final pending = await _pendingStore.read();
    final context = await _readContext();
    await _checkCurrent(revision, credentials, context);
    final staged = expectedStaging;
    if (context.providerId != staged.providerId ||
        context.applicationId != staged.applicationId) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.authentication,
      );
    }
    if (selections.any(
      (selection) => selection.remote.reference.providerId != staged.providerId,
    )) {
      throw BankingException(
        providerId: staged.providerId,
        failure: BankingFailure.rejected,
      );
    }
    for (final selection in selections) {
      final scale = BankMoney.scales[selection.remote.currency];
      if (scale == null || scale > 2) {
        throw const FormatException(
          'Remote account currency is not supported by the current display',
        );
      }
    }
    final links = selections
        .map(
          (selection) => BankAccountLink(
            uid: selection.remote.reference.remoteId,
            identificationHashes: selection.remote.reference.identityKeys
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toSet(),
            iban: selection.remote.iban,
            newAccount: selection.newAccount?.id == null
                ? selection.newAccount?.copy(startingValue: 0)
                : selection.newAccount,
            currency: selection.remote.currency,
          ),
        )
        .toList(growable: false);
    BankSessionRecoveryRecord? retired;
    final journal = _recoveryStore;
    final connection = await _coordinator.commit(() async {
      await _checkCurrent(revision, credentials, context);
      if (staged.remoteConnectionId != null &&
          staged.remoteConnectionId != staged.pendingRemoteConnectionId) {
        if (journal == null) throw const BankSessionRecoveryStorageException();
        retired = BankSessionRecoveryRecord(
          providerId: staged.providerId,
          applicationId: staged.applicationId,
          authorizationId: 'retired:${staged.pendingAuthorizationId!}',
          remoteConnectionId: staged.remoteConnectionId,
          phase: BankSessionRecoveryPhase.knownSession,
          updatedAt: _clock().toUtc(),
        );
        final existing = (await journal.read()).where(
          (record) => record.sameAttempt(retired!),
        );
        if (existing.isNotEmpty) {
          retired = existing.single;
        } else if (!await journal.upsert(retired!)) {
          throw const BankSessionRecoveryStorageException();
        }
      }
      try {
        return await _connections.activateStagedConnection(
          connectionId,
          links,
          expectedStaging: staged,
          clock: _clock,
          isAuthorizationCurrent: () => _isCurrent(revision, credentials),
        );
      } catch (_) {
        if (retired != null) {
          try {
            await journal!.removeIfCurrent(retired!);
          } catch (_) {}
        }
        rethrow;
      }
    });
    if (pending != null && _pendingOwns(pending, staged)) {
      await _clearOwnedPending(pending);
    }
    if (retired != null) {
      try {
        await recoverSessions();
      } catch (_) {}
    }
    return connection;
  }

  bool _pendingOwns(
    PendingBankAuthorization pending,
    BankConnection connection,
  ) =>
      pending.providerId == connection.providerId &&
      pending.applicationId == connection.applicationId &&
      pending.authorizationId == connection.pendingAuthorizationId &&
      (pending.stagedConnectionId == connection.id ||
          pending.stagedConnectionId == null);

  Future<bool> _snapshotCurrent(BankConnection connection) async =>
      (await _connections.findById(
        connection.id!,
      ))?.sameLifecycle(connection) ??
      false;

  Future<List<ResumableBankConnection>> resumeAwaitingImports({
    BankConnection? expectedStaging,
    void Function(BankConnection settled, BankingFailure? failure)? onRejected,
  }) async {
    final revision = _coordinator.revision;
    final credentials = _credentialRevision?.call();
    final result = <ResumableBankConnection>[];
    for (final connection in await _connections.selectAwaitingImport()) {
      if (expectedStaging != null &&
          !connection.sameLifecycle(expectedStaging)) {
        continue;
      }
      if (!{
        BankConnectionStatus.awaitingImport,
        BankConnectionStatus.active,
        BankConnectionStatus.expired,
        BankConnectionStatus.reauthRequired,
      }.contains(connection.status)) {
        continue;
      }
      final remoteId = connection.pendingRemoteConnectionId!;
      final pending = await _pendingStore.read();
      try {
        await _checkCurrent(revision, credentials);
        final reference = await _reference(connection, remoteId);
        _assertCurrent(revision, credentials);
        final details = await _consent.getConnection(reference);
        await _reference(connection, remoteId);
        await _checkCurrent(revision, credentials);
        if (!await _snapshotCurrent(connection)) continue;
        if (details.reference.providerId != connection.providerId ||
            details.reference.remoteId != remoteId) {
          throw const BankingException(
            providerId: 'application',
            failure: BankingFailure.invalidResponse,
          );
        }
        if (details.status == BankingConnectionStatus.pending) continue;
        final status =
            details.status == BankingConnectionStatus.active &&
                (details.isExpiredAt(_clock().toUtc()) ||
                    !connection.pendingValidUntil!.isAfter(_clock().toUtc()))
            ? BankConnectionStatus.expired
            : _localStatus(details.status);
        if (status != BankConnectionStatus.awaitingImport) {
          final settled = await _rejectStagedConnection(
            connection,
            status,
            pending,
          );
          if (settled != null) onRejected?.call(settled, null);
          continue;
        }
        if (await _snapshotCurrent(connection)) {
          result.add(
            ResumableBankConnection(connection: connection, details: details),
          );
        }
      } on BankingException catch (error) {
        if (!_isCurrent(revision, credentials) ||
            !await _snapshotCurrent(connection)) {
          continue;
        }
        final status = _statusForFailure(error.failure);
        if (status == null) rethrow;
        final settled = await _rejectStagedConnection(
          connection,
          status,
          pending,
        );
        if (settled != null) onRejected?.call(settled, error.failure);
      }
    }
    return result;
  }

  Future<BankConnection?> _rejectStagedConnection(
    BankConnection connection,
    BankConnectionStatus failedStatus,
    PendingBankAuthorization? pending,
  ) async {
    final changed =
        connection.remoteConnectionId == null ||
            failedStatus == BankConnectionStatus.reauthRequired
        ? await _connections.failStagedConnectionIfCurrent(
            connection,
            failedStatus,
            clock: _clock,
          )
        : await _connections.discardStagedConnectionIfCurrent(
            connection,
            clock: _clock,
          );
    if (changed != null &&
        pending != null &&
        _pendingOwns(pending, connection)) {
      await _clearOwnedPending(pending);
    }
    return changed;
  }

  Future<BankConnectionStatus> refreshConnectionState(
    BankConnection connection,
  ) async {
    if (connection.id == null || connection.remoteConnectionId == null) {
      return connection.status;
    }
    final revision = _coordinator.revision;
    final credentials = _credentialRevision?.call();
    BankConnectionStatus status;
    try {
      final reference = await _reference(
        connection,
        connection.remoteConnectionId!,
      );
      _assertCurrent(revision, credentials);
      final details = await _consent.getConnection(reference);
      await _reference(connection, connection.remoteConnectionId!);
      await _checkCurrent(revision, credentials);
      if (details.reference.providerId != connection.providerId ||
          details.reference.remoteId != connection.remoteConnectionId) {
        throw const BankingException(
          providerId: 'application',
          failure: BankingFailure.invalidResponse,
        );
      }
      status = switch (details.status) {
        BankingConnectionStatus.active =>
          details.validUntil.isAfter(_clock().toUtc())
              ? BankConnectionStatus.active
              : BankConnectionStatus.expired,
        BankingConnectionStatus.expired => BankConnectionStatus.expired,
        BankingConnectionStatus.revoked ||
        BankingConnectionStatus.closed => BankConnectionStatus.revoked,
        BankingConnectionStatus.cancelled ||
        BankingConnectionStatus.invalid => BankConnectionStatus.reauthRequired,
        BankingConnectionStatus.pending => BankConnectionStatus.authorizing,
      };
    } on BankingException catch (error) {
      if (!_isCurrent(revision, credentials)) {
        return (await _connections.selectById(connection.id!)).status;
      }
      final mapped = _statusForFailure(error.failure);
      if (mapped == null) rethrow;
      status = mapped;
    }
    final changed = await _connections.markStatusIfCurrent(
      connection,
      status,
      clock: _clock,
    );
    return changed?.status ??
        (await _connections.selectById(connection.id!)).status;
  }

  Future<void> revoke(BankConnection connection) async {
    if (connection.id == null) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    final revision = _coordinator.revision;
    final credentials = _credentialRevision?.call();
    final pending = await _pendingStore.read();
    final ids = {
      if (connection.pendingRemoteConnectionId != null)
        connection.pendingRemoteConnectionId!,
      if (connection.remoteConnectionId != null) connection.remoteConnectionId!,
    };
    if (ids.isEmpty) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    for (final id in ids) {
      await _reference(connection, id);
    }
    await _checkCurrent(revision, credentials);
    final revoking = await _connections.markStatusIfCurrent(
      connection,
      BankConnectionStatus.revocationPending,
      clock: _clock,
    );
    if (revoking == null) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    for (final id in ids) {
      await _checkCurrent(revision, credentials);
      if (!await _snapshotCurrent(revoking)) {
        throw const BankingException(
          providerId: 'application',
          failure: BankingFailure.rejected,
        );
      }
      try {
        final reference = await _reference(connection, id);
        _assertCurrent(revision, credentials);
        final handler = _cleanupObsoleteConnection;
        if (handler != null) {
          final deleted = await handler(
            ObsoleteBankConnection(
              providerId: connection.providerId,
              applicationId: connection.applicationId,
              authorizationId: connection.pendingAuthorizationId ?? 'revoke',
              remoteConnectionId: id,
              attemptRevision: revision,
              reason: 'remote_revocation',
            ),
          );
          if (!deleted) {
            throw const BankingException(
              providerId: 'application',
              failure: BankingFailure.authentication,
            );
          }
        } else {
          await _consent.revokeConnection(reference);
        }
      } on BankingException catch (error) {
        if (!error.confirmsMissingConnection) rethrow;
      }
    }
    await _checkCurrent(revision, credentials);
    final changed = await _connections.finalizeRemoteRevocationIfCurrent(
      revoking,
      clock: _clock,
    );
    if (changed == null) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    if (pending != null && _pendingOwns(pending, connection)) {
      await _clearOwnedPending(pending);
    }
  }

  Future<void> disconnectLocally(BankConnection connection) async {
    if (connection.id == null) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    final pending = await _pendingStore.read();
    final changed = await _connections.disconnectLocallyIfCurrent(
      connection,
      clock: _clock,
    );
    if (changed == null) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    if (pending != null && _pendingOwns(pending, connection)) {
      await _clearOwnedPending(pending);
    }
  }

  Future<BankInstitution> _freshReconnectBankInstitution(
    BankInstitution selected,
    int connectionId,
    String applicationId,
  ) async {
    final connection = await _connections.selectById(connectionId);
    if (connection.providerId != selected.providerId ||
        connection.applicationId != applicationId ||
        connection.institutionName != selected.name ||
        connection.institutionCountry != selected.country) {
      throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      );
    }
    final current = await _institutions.getInstitutions(
      country: selected.country,
    );
    return current.firstWhere(
      (item) =>
          item.providerId == selected.providerId &&
          item.id == selected.id &&
          item.name == selected.name &&
          item.country == selected.country,
      orElse: () => throw const BankingException(
        providerId: 'application',
        failure: BankingFailure.rejected,
      ),
    );
  }

  BankConnectionStatus _localStatus(BankingConnectionStatus status) =>
      switch (status) {
        BankingConnectionStatus.active => BankConnectionStatus.awaitingImport,
        BankingConnectionStatus.expired => BankConnectionStatus.expired,
        BankingConnectionStatus.revoked ||
        BankingConnectionStatus.closed => BankConnectionStatus.revoked,
        BankingConnectionStatus.cancelled ||
        BankingConnectionStatus.invalid => BankConnectionStatus.reauthRequired,
        BankingConnectionStatus.pending => BankConnectionStatus.authorizing,
      };

  BankConnectionStatus? _statusForFailure(BankingFailure kind) =>
      switch (kind) {
        BankingFailure.connectionExpired => BankConnectionStatus.expired,
        BankingFailure.connectionRevoked ||
        BankingFailure.connectionClosed ||
        BankingFailure.notFound => BankConnectionStatus.revoked,
        BankingFailure.authentication ||
        BankingFailure.forbidden => BankConnectionStatus.reauthRequired,
        _ => null,
      };

  Future<BankingConnectionReference> _reference(
    BankConnection connection,
    String remoteId,
  ) async {
    final context = await _readContext();
    if (connection.providerId != context.providerId ||
        connection.applicationId != context.applicationId) {
      throw BankingException(
        providerId: connection.providerId,
        failure: BankingFailure.authentication,
      );
    }
    return BankingConnectionReference(
      providerId: connection.providerId,
      remoteId: remoteId,
    );
  }

  String _newState() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);
}
