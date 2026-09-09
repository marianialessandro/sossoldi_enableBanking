import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:url_launcher/url_launcher.dart';

import '../../model/bank_account.dart';
import '../../model/bank_connection.dart';
import '../database/repositories/bank_connection_repository.dart';
import 'enable_banking_api.dart';
import 'enable_banking_config.dart';
import 'enable_banking_credentials_store.dart';
import 'enable_banking_deeplink_service.dart';
import 'enable_banking_exception.dart';
import 'enable_banking_platform_support.dart';
import 'models/aspsp.dart';
import 'models/bank_money.dart';
import 'models/eb_account.dart';
import 'models/eb_session.dart';
import 'models/eb_session_details.dart';
import 'pending_bank_authorization_store.dart';

const _kDefaultConsentValidity = Duration(days: 90);
const _kAuthorizationLifetime = Duration(minutes: 15);

class AuthorizationAttempt {
  final Uri url;
  final DateTime consentValidUntil;

  const AuthorizationAttempt({
    required this.url,
    required this.consentValidUntil,
  });
}

class AuthorizationLaunchResult {
  final Uri url;
  final bool opened;

  const AuthorizationLaunchResult({required this.url, required this.opened});
}

class StagedBankSession {
  final BankConnection connection;
  final EbSession? createdSession;

  const StagedBankSession({required this.connection, this.createdSession});
}

class ResumableBankSession {
  final BankConnection connection;
  final EbSessionDetails details;

  const ResumableBankSession({required this.connection, required this.details});
}

typedef AuthorizationUrlLauncher = Future<bool> Function(Uri url);

class BankConsentLifecycleService {
  final EnableBankingApi _api;
  final EnableBankingCredentialsStore _credentialsStore;
  final PendingBankAuthorizationStore _pendingStore;
  final BankConnectionRepository _connections;
  final DateTime Function() _clock;
  final bool Function() _callbackSupported;
  final Random _random;

  Future<void> _callbackQueue = Future.value();

  BankConsentLifecycleService({
    required EnableBankingApi api,
    required EnableBankingCredentialsStore credentialsStore,
    required PendingBankAuthorizationStore pendingStore,
    required BankConnectionRepository connections,
    DateTime Function()? clock,
    bool Function()? callbackSupported,
    Random? random,
  }) : _api = api,
       _credentialsStore = credentialsStore,
       _pendingStore = pendingStore,
       _connections = connections,
       _clock = clock ?? DateTime.now,
       _callbackSupported =
           callbackSupported ?? EnableBankingPlatformSupport.supportsCallback,
       _random = random ?? Random.secure();

  Future<AuthorizationAttempt> startAuthorization(
    Aspsp selectedAspsp, {
    int? reconnectConnectionId,
  }) async {
    if (!_callbackSupported()) {
      throw const EnableBankingException(
        message: 'Bank authorization is not supported on this platform',
        kind: EnableBankingFailureKind.invalidRequest,
      );
    }
    final credentials = await _credentialsStore.readCredentials();
    if (credentials == null) {
      throw const EnableBankingException(
        message: 'Enable Banking credentials are missing',
        kind: EnableBankingFailureKind.applicationAuthentication,
      );
    }
    final config = credentials.config;
    validateEnableBankingRedirect(
      config.redirectUri,
      registeredRedirects: config.redirectUrls,
    );
    final existingPending = await _pendingStore.read();
    if (existingPending != null) {
      if (!existingPending.expiresAt.isAfter(_clock().toUtc())) {
        await _pendingStore.clear();
      } else if (existingPending.applicationId == config.appId &&
          existingPending.redirectUri == config.redirectUri &&
          existingPending.aspspName == selectedAspsp.name &&
          existingPending.aspspCountry == selectedAspsp.country &&
          existingPending.reconnectConnectionId == reconnectConnectionId) {
        return AuthorizationAttempt(
          url: Uri.parse(existingPending.authorizationUrl),
          consentValidUntil: existingPending.consentValidUntil,
        );
      } else {
        throw const EnableBankingException(
          message: 'Another bank authorization is already pending',
          kind: EnableBankingFailureKind.invalidRequest,
        );
      }
    }

    final aspsp = reconnectConnectionId == null
        ? selectedAspsp
        : await _freshReconnectAspsp(
            selectedAspsp,
            reconnectConnectionId,
            config.appId,
          );
    if (!aspsp.psuTypes.contains('personal')) {
      throw const EnableBankingException(
        message: 'The selected bank does not support personal banking',
        kind: EnableBankingFailureKind.invalidRequest,
      );
    }
    final maximum = aspsp.maximumConsentValidity;
    final validity = maximum == null
        ? _kDefaultConsentValidity
        : Duration(
            seconds: min(_kDefaultConsentValidity.inSeconds, max(0, maximum)),
          );
    if (validity == Duration.zero) {
      throw const EnableBankingException(
        message: 'The selected bank returned an invalid consent duration',
        kind: EnableBankingFailureKind.invalidResponse,
      );
    }

    final now = _clock().toUtc();
    final state = _newState();
    final consentValidUntil = now.add(validity);
    final authorization = await _api.startAuthorization(
      aspspName: aspsp.name,
      aspspCountry: aspsp.country,
      state: state,
      validUntil: consentValidUntil,
      redirectUri: config.redirectUri,
    );
    final authorizationUri = Uri.tryParse(authorization.url);
    if (authorizationUri == null ||
        !authorizationUri.hasScheme ||
        authorizationUri.scheme != 'https') {
      throw const EnableBankingException(
        message: 'Enable Banking returned an invalid authorization URL',
        kind: EnableBankingFailureKind.invalidResponse,
      );
    }
    await _pendingStore.save(
      PendingBankAuthorization(
        state: state,
        authorizationId: authorization.authorizationId,
        authorizationUrl: authorization.url,
        applicationId: config.appId,
        aspspName: aspsp.name,
        aspspCountry: aspsp.country,
        redirectUri: config.redirectUri,
        expiresAt: now.add(_kAuthorizationLifetime),
        consentValidUntil: consentValidUntil,
        reconnectConnectionId: reconnectConnectionId,
      ),
    );
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

  Future<void> cancelAuthorization() => _pendingStore.clear();

  Future<bool> clearExpiredAuthorization() async {
    final pending = await _pendingStore.read();
    if (pending == null || pending.expiresAt.isAfter(_clock().toUtc())) {
      return false;
    }
    await _pendingStore.clear();
    return true;
  }

  Future<StagedBankSession> completeCallback(EnableBankingCallback callback) {
    final completer = Completer<void>();
    final previous = _callbackQueue;
    _callbackQueue = previous.then((_) => completer.future);
    return previous.then((_) async {
      try {
        return await _completeCallback(callback);
      } finally {
        completer.complete();
      }
    });
  }

  Future<CallbackDisposition> handleCallback(
    EnableBankingCallback callback, {
    Future<void> Function(StagedBankSession session)? onStaged,
    Future<void> Function(Object error)? onError,
  }) async {
    try {
      final staged = await completeCallback(callback);
      if (onStaged != null) await onStaged(staged);
      return CallbackDisposition.terminal;
    } on EnableBankingException catch (error) {
      if (onError != null) await onError(error);
      return error.isRetryable
          ? CallbackDisposition.retryable
          : CallbackDisposition.terminal;
    } catch (error) {
      if (onError != null) await onError(error);
      return CallbackDisposition.retryable;
    }
  }

  Future<StagedBankSession> _completeCallback(
    EnableBankingCallback callback,
  ) async {
    final pending = await _pendingStore.read();
    if (pending == null) {
      throw const EnableBankingException(
        message: 'No bank authorization is pending',
        kind: EnableBankingFailureKind.invalidRequest,
      );
    }
    if (callback.state == null || callback.state != pending.state) {
      throw const EnableBankingException(
        message: 'OAuth callback state does not match',
        kind: EnableBankingFailureKind.invalidRequest,
      );
    }
    if (!pending.expiresAt.isAfter(_clock().toUtc())) {
      await _pendingStore.clear();
      throw const EnableBankingException(
        message: 'Bank authorization has expired',
        kind: EnableBankingFailureKind.sessionExpired,
      );
    }
    if (callback.error != null) {
      await _pendingStore.clear();
      throw EnableBankingException(
        error: callback.error,
        message: callback.errorDescription ?? 'Authorization was cancelled',
        kind: EnableBankingFailureKind.invalidRequest,
      );
    }
    if (callback.code == null || callback.code!.trim().isEmpty) {
      throw const EnableBankingException(
        message: 'OAuth callback has no authorization code',
        kind: EnableBankingFailureKind.invalidRequest,
      );
    }

    if (pending.stagedConnectionId case final id?) {
      return StagedBankSession(connection: await _connections.selectById(id));
    }
    final durable = await _connections.findByPendingAuthorizationId(
      pending.authorizationId,
    );
    if (durable != null) {
      await _pendingStore.save(
        pending.copy(
          stagedConnectionId: durable.id,
          phase: PendingAuthorizationPhase.sessionStaged,
        ),
      );
      return StagedBankSession(connection: durable);
    }

    final session = await _api.createSession(callback.code!);
    if (session.aspspName != pending.aspspName ||
        session.aspspCountry != pending.aspspCountry) {
      throw const EnableBankingException(
        message: 'Created session does not match the selected bank',
        kind: EnableBankingFailureKind.invalidResponse,
      );
    }
    final connection = await _connections.stageSession(
      authorizationId: pending.authorizationId,
      applicationId: pending.applicationId,
      aspspName: session.aspspName,
      aspspCountry: session.aspspCountry,
      sessionId: session.sessionId,
      validUntil: session.validUntil,
      psuType: session.psuType ?? 'personal',
      reconnectConnectionId: pending.reconnectConnectionId,
    );
    await _pendingStore.save(
      pending.copy(
        stagedConnectionId: connection.id,
        phase: PendingAuthorizationPhase.sessionStaged,
      ),
    );
    return StagedBankSession(connection: connection, createdSession: session);
  }

  Future<BankConnection> activateSession(
    int connectionId,
    List<({EbAccount remote, BankAccount? newAccount})> selections,
  ) async {
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
            uid: selection.remote.uid,
            identificationHashes: selection.remote.stableHashes,
            iban: selection.remote.iban,
            newAccount: selection.newAccount?.id == null
                ? selection.newAccount?.copy(startingValue: 0)
                : selection.newAccount,
            currency: selection.remote.currency,
          ),
        )
        .toList(growable: false);
    final connection = await _connections.activateStagedSession(
      connectionId,
      links,
    );
    final pending = await _pendingStore.read();
    if (pending?.stagedConnectionId == connectionId) {
      await _pendingStore.clear();
    }
    return connection;
  }

  Future<List<ResumableBankSession>> resumeAwaitingImports() async {
    final result = <ResumableBankSession>[];
    for (final connection in await _connections.selectAwaitingImport()) {
      final sessionId = connection.pendingSessionId;
      if (sessionId == null) continue;
      try {
        final details = await _api.getSession(sessionId);
        final localStatus = _localStatus(details.status);
        if (localStatus != BankConnectionStatus.awaitingImport) {
          await _rejectStagedSession(connection, localStatus);
          continue;
        }
        result.add(
          ResumableBankSession(connection: connection, details: details),
        );
      } on EnableBankingException catch (error) {
        final status = _statusForFailure(error.kind);
        if (status != null) {
          await _rejectStagedSession(connection, status);
          continue;
        }
        rethrow;
      }
    }
    return result;
  }

  Future<void> _rejectStagedSession(
    BankConnection connection,
    BankConnectionStatus failedStatus,
  ) async {
    final id = connection.id!;
    if (failedStatus == BankConnectionStatus.reauthRequired) {
      await _connections.markStatus(id, failedStatus);
      return;
    }
    if (connection.sessionId == null) {
      await _connections.failStagedSession(id, failedStatus);
    } else {
      await _connections.discardStagedSession(id);
    }
    final pending = await _pendingStore.read();
    if (pending?.stagedConnectionId == id) await _pendingStore.clear();
  }

  Future<BankConnectionStatus> refreshConnectionState(
    BankConnection connection,
  ) async {
    final id = connection.id;
    final sessionId = connection.sessionId;
    if (id == null || sessionId == null) {
      return connection.status;
    }
    try {
      final details = await _api.getSession(sessionId);
      final status = switch (details.status) {
        EbSessionStatus.authorized =>
          details.validUntil.isAfter(_clock().toUtc())
              ? BankConnectionStatus.active
              : BankConnectionStatus.expired,
        EbSessionStatus.expired => BankConnectionStatus.expired,
        EbSessionStatus.revoked ||
        EbSessionStatus.closed => BankConnectionStatus.revoked,
        EbSessionStatus.cancelled ||
        EbSessionStatus.invalid => BankConnectionStatus.reauthRequired,
        EbSessionStatus.pendingAuthorization ||
        EbSessionStatus.returnedFromBank => BankConnectionStatus.authorizing,
      };
      await _connections.markStatus(id, status);
      return status;
    } on EnableBankingException catch (error) {
      final status = _statusForFailure(error.kind);
      if (status == null) rethrow;
      await _connections.markStatus(id, status);
      return status;
    }
  }

  Future<void> revoke(BankConnection connection) async {
    if (connection.id == null || connection.sessionId == null) {
      throw const EnableBankingException(
        message: 'Connection has no revocable session',
        kind: EnableBankingFailureKind.invalidRequest,
      );
    }
    await _connections.markStatus(
      connection.id!,
      BankConnectionStatus.revocationPending,
    );
    try {
      await _api.deleteSession(connection.sessionId!);
    } on EnableBankingException catch (error) {
      if (!error.confirmsMissingSession) rethrow;
    }
    await _connections.finalizeRemoteRevocation(connection.id!);
  }

  Future<void> disconnectLocally(BankConnection connection) async {
    if (connection.id == null) {
      throw const EnableBankingException(
        message: 'Connection is not persisted',
        kind: EnableBankingFailureKind.invalidRequest,
      );
    }
    await _connections.disconnectLocally(connection.id!);
  }

  Future<Aspsp> _freshReconnectAspsp(
    Aspsp selected,
    int connectionId,
    String applicationId,
  ) async {
    final connection = await _connections.selectById(connectionId);
    if (connection.applicationId != applicationId ||
        connection.aspspName != selected.name ||
        connection.aspspCountry != selected.country) {
      throw const EnableBankingException(
        message: 'Reconnect target does not match the selected bank',
        kind: EnableBankingFailureKind.invalidRequest,
      );
    }
    final current = await _api.getAspsps(country: selected.country);
    return current.firstWhere(
      (item) => item.name == selected.name && item.country == selected.country,
      orElse: () => throw const EnableBankingException(
        message: 'The bank is no longer available for personal banking',
        kind: EnableBankingFailureKind.invalidRequest,
      ),
    );
  }

  BankConnectionStatus _localStatus(EbSessionStatus status) => switch (status) {
    EbSessionStatus.authorized => BankConnectionStatus.awaitingImport,
    EbSessionStatus.expired => BankConnectionStatus.expired,
    EbSessionStatus.revoked ||
    EbSessionStatus.closed => BankConnectionStatus.revoked,
    EbSessionStatus.cancelled ||
    EbSessionStatus.invalid => BankConnectionStatus.reauthRequired,
    EbSessionStatus.pendingAuthorization ||
    EbSessionStatus.returnedFromBank => BankConnectionStatus.authorizing,
  };

  BankConnectionStatus? _statusForFailure(EnableBankingFailureKind kind) =>
      switch (kind) {
        EnableBankingFailureKind.sessionExpired => BankConnectionStatus.expired,
        EnableBankingFailureKind.sessionRevoked ||
        EnableBankingFailureKind.sessionClosed ||
        EnableBankingFailureKind.notFound => BankConnectionStatus.revoked,
        EnableBankingFailureKind.applicationAuthentication =>
          BankConnectionStatus.reauthRequired,
        _ => null,
      };

  String _newState() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);
}
