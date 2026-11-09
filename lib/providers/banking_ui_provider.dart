import 'dart:async';
import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../model/bank_account.dart';
import '../model/bank_connection.dart';
import '../services/banking/bank_institution.dart';
import '../services/banking/banking_account.dart';
import '../services/banking/banking_account_import_result.dart';
import '../services/banking/banking_request_context.dart';
import '../services/banking/banking_balance.dart';
import '../services/banking/banking_exception.dart';
import '../services/banking/banking_reference.dart';
import '../services/banking/lifecycle/bank_authorization_result.dart';
import '../services/banking/lifecycle/pending_bank_authorization.dart';
import '../services/banking/lifecycle/bank_session_recovery_store.dart';
import '../services/banking/lifecycle/banking_platform_support.dart';
import '../services/banking/sync/bank_sync_lifecycle.dart';
import '../services/banking/sync/bank_sync_result.dart';
import '../services/banking/sync/bank_sync_request.dart';
import '../services/banking/sync/bank_sync_service.dart';
import '../services/database/repositories/bank_connection_repository.dart';
import '../services/database/repositories/bank_sync_repository.dart';
import '../services/database/sossoldi_database.dart';
import 'accounts_provider.dart';
import 'banking_provider.dart';
import 'dashboard_provider.dart';
import 'statistics_provider.dart';
import 'transactions_provider.dart';

export 'banking_provider.dart';

part 'banking_ui_provider.g.dart';

class ConnectBankFlowException implements Exception {
  final String message;
  const ConnectBankFlowException(this.message);
}

String bankingErrorMessage(Object error) {
  if (error is BankSessionOutcomeUnknownException) {
    return 'The bank connection outcome is unknown. Check the connection with your bank before starting again.';
  }
  if (error is ConnectBankFlowException) return error.message;
  if (error is SocketException || error is TimeoutException) {
    return 'The bank could not be reached. Check your connection and try again.';
  }
  if (error is EnableBankingAuthException) {
    return 'Check your Enable Banking application ID and private key in Bank sync settings.';
  }
  if (error is EnableBankingException) {
    return switch (error.kind) {
      EnableBankingFailureKind.applicationAuthentication =>
        'Check your Enable Banking credentials in Bank sync settings.',
      EnableBankingFailureKind.sessionExpired ||
      EnableBankingFailureKind.sessionRevoked ||
      EnableBankingFailureKind.sessionClosed ||
      EnableBankingFailureKind.notFound =>
        'The bank connection is no longer valid. Reconnect the bank.',
      EnableBankingFailureKind.rateLimited =>
        'The bank is receiving too many requests. Try again later.',
      EnableBankingFailureKind.network ||
      EnableBankingFailureKind.timeout ||
      EnableBankingFailureKind.server =>
        'The bank could not be reached. Check your connection and try again.',
      _ => 'The bank could not complete this request. Try again.',
    };
  }
  if (error is BankingException) {
    return switch (error.failure) {
      BankingFailure.authentication || BankingFailure.forbidden =>
        'Check your Enable Banking credentials and reconnect the bank.',
      BankingFailure.connectionExpired =>
        'The consent has expired. Reconnect the bank.',
      BankingFailure.connectionRevoked ||
      BankingFailure.connectionClosed ||
      BankingFailure.notFound => 'The bank connection is no longer available.',
      BankingFailure.rateLimited =>
        'The bank is receiving too many requests. Try again later.',
      BankingFailure.unavailable =>
        'The bank is temporarily unavailable. Try again.',
      _ =>
        'The bank could not complete this request. Try again or restart the connection.',
    };
  }
  return 'Could not complete the bank request. Please try again.';
}

String bankAccountCount(int count) =>
    '$count ${count == 1 ? 'account' : 'accounts'}';

String bankSyncMessage(BankSyncSummary result) {
  final warnings = result.accounts
      .expand((account) => account.warnings)
      .toSet();
  if (warnings.contains('server_clock_regressed')) {
    return 'The bank returned an older sync time. Previous data was kept. Try syncing again later.';
  }
  if (warnings.contains('balance_mismatch')) {
    return 'The bank balance does not match the available transactions. Previous data was kept. Try syncing again or check the missing history with your bank.';
  }
  if (warnings.any(
    {
      'api_connectionRevoked',
      'api_connectionClosed',
      'api_notFound',
      'api_connectionExpired',
      'consent_expired',
      'consent_or_credentials_unavailable',
    }.contains,
  )) {
    return 'The bank connection needs your attention. Reconnect the bank or check your credentials.';
  }
  if (warnings.contains('account_not_found')) {
    return 'The bank could not provide an account. Check its status with your bank, and reconnect any connection marked as requiring reconnection.';
  }
  if (warnings.any(
    {'api_authentication', 'api_forbidden', 'credentials_changed'}.contains,
  )) {
    return 'Check your Enable Banking credentials in Bank sync settings before retrying.';
  }
  if (warnings.contains('history_overlap_missing')) {
    return 'The returned history does not reach the previous sync. Some transactions may be missing. Check the history with your bank.';
  }
  if (warnings.contains('initial_balance_unverified')) {
    return 'The bank did not provide a verifiable booked balance. The first sync is incomplete. Try again later.';
  }
  if (warnings.contains('manual_context_required')) {
    return 'This bank requires additional details for an interactive refresh. Complete the request to continue.';
  }
  if ((result.status == BankSyncStatus.success ||
          result.status == BankSyncStatus.noChange) &&
      warnings.contains('no_comparable_booked_balance')) {
    return 'Transactions checked. The bank balance could not be verified. Try syncing again later.';
  }
  if ((result.status == BankSyncStatus.success ||
          result.status == BankSyncStatus.noChange) &&
      warnings.contains('empty_account_history_unverified')) {
    return 'The zero booked balance was verified. The bank returned no booked transactions; earlier history could not be verified.';
  }
  if ((result.status == BankSyncStatus.success ||
          result.status == BankSyncStatus.noChange) &&
      warnings.contains('bank_default_history_fallback')) {
    return 'Sync completed using the history available from your bank. Earlier transactions may not be available.';
  }
  final count = result.accounts.fold<int>(
    0,
    (total, account) => total + account.inserted,
  );
  return switch (result.status) {
    BankSyncStatus.success =>
      'Synced $count new ${count == 1 ? 'transaction' : 'transactions'}',
    BankSyncStatus.noChange => 'Bank accounts are up to date',
    BankSyncStatus.partial =>
      'Some accounts could not be synced. Retry from Linked banks.',
    BankSyncStatus.retryableFailure =>
      'Sync could not finish. Please retry later.',
    BankSyncStatus.terminalFailure =>
      'Sync could not finish. Check the consent and account currency.',
    BankSyncStatus.skipped =>
      'No accounts were due for sync. Please wait before retrying.',
  };
}

bool bankSyncNeedsAttention(BankSyncSummary result) => result.accounts.any(
  (account) =>
      (!account.completed && account.status != BankSyncStatus.skipped) ||
      account.warnings.any(
        {
          'no_comparable_booked_balance',
          'empty_account_history_unverified',
          'bank_default_history_fallback',
          'balance_mismatch',
          'history_overlap_missing',
        }.contains,
      ),
);

@riverpod
Future<BankSyncSummary> bankConnectionSyncStatus(Ref ref, int connectionId) =>
    ref.watch(bankSyncRepositoryProvider).latestResults(connectionId);

@Riverpod(keepAlive: true)
class BankRecoveryIssue extends _$BankRecoveryIssue {
  String? _recoveryIssue;
  String? _callbackIssue;
  String? _importIssue;
  final List<BankConnection?> _importConnections = [];
  String? _syncIssue;
  String? _pendingCleanupIssue;
  @override
  String? build() => null;
  void report(Object error) => reportMessage(bankingErrorMessage(error));
  void reportMessage(String message) {
    _syncIssue = message;
    _publish();
  }

  void reportRecovery(String? message) {
    _recoveryIssue = message;
    _publish();
  }

  void reportCallbackRecovery(String? message) {
    _callbackIssue = message;
    _publish();
  }

  void reportPendingCleanup(String? message) {
    _pendingCleanupIssue = message;
    _publish();
  }

  void _publish() {
    final messages = [
      _recoveryIssue,
      _callbackIssue,
      _importIssue,
      _syncIssue,
      _pendingCleanupIssue,
    ].nonNulls.toSet();
    state = messages.isEmpty ? null : messages.join('\n');
  }

  void reportImportRecovery(BankConnection? connection) {
    if (connection != null) {
      _importConnections.removeWhere((item) => item?.id == connection.id);
    }
    if (!_importConnections.any((item) => item == null && connection == null)) {
      _importConnections.add(connection);
    }
    _importIssue =
        'Could not resume the account import. Try again. Other connected banks can still sync.';
    _publish();
  }

  void clearImportRecovery(BankConnection connection) {
    _importConnections.removeWhere(
      (item) => item?.sameLifecycle(connection) == true,
    );
    _importIssue = _importConnections.isEmpty
        ? null
        : 'Could not resume the account import. Try again. Other connected banks can still sync.';
    _publish();
  }

  void clear() {
    _syncIssue = null;
    _publish();
  }
}

class BankAccountImportSelection {
  final BankConnection expectedStaging;
  final BankingAccount account;
  final String name;
  final String symbol;
  final int color;

  const BankAccountImportSelection({
    required this.expectedStaging,
    required this.account,
    required this.name,
    required this.symbol,
    required this.color,
  });
}

enum BankRecoveryActionKind { cancel, revoke, local, resume }

enum BankRecoveryActionStatus { running, applied, stale, failed }

class BankRecoveryActionResult {
  final BankRecoveryActionKind kind;
  final BankRecoveryActionStatus status;
  final String message;
  final BankConnection? connection;
  final BankAuthorizationOwner? authorizationOwner;
  final PendingBankAuthorization? pendingCleanup;
  const BankRecoveryActionResult({
    required this.kind,
    required this.status,
    required this.message,
    this.connection,
    this.authorizationOwner,
    this.pendingCleanup,
  });
  bool get applied => status == BankRecoveryActionStatus.applied;
  bool concerns(BankConnection value) =>
      connection?.copy(status: value.status).sameLifecycle(value) == true;
}

const bankRecoveryStaleMessage =
    'This bank connection changed. Review its current status before trying again.';
const bankRecoveryCredentialsMessage =
    'Remote consent cannot be revoked with the current Enable Banking credentials. Restore the original credentials and try again, or disconnect locally.';

const bankPendingCleanupMessage =
    'Could not complete bank recovery cleanup. Try again. Other connected banks can still sync.';

class ConnectBankFlowState {
  final List<BankInstitution> aspsps;
  final List<BankingAccount> importable;
  final BankConnection? connection;
  final bool authorizing;
  final BankAuthorizationOwner? authorizationOwner;
  final List<BankRecoveryActionResult> recoveryActions;
  final BankRecoveryActionResult? recoveryNotice;
  final List<BankRecoveryActionResult> recoveryNotices;
  final PendingBankAuthorization? pendingCleanup;
  final List<BankingAccountImportOutcome> outcomes;
  final BankingImportStatus importStatus;
  final BankingImportFailureScope? failureScope;

  const ConnectBankFlowState({
    this.aspsps = const [],
    this.importable = const [],
    this.connection,
    this.authorizing = false,
    this.authorizationOwner,
    this.recoveryActions = const [],
    this.recoveryNotice,
    this.recoveryNotices = const [],
    this.pendingCleanup,
    this.outcomes = const [],
    this.importStatus = BankingImportStatus.idle,
    this.failureScope,
  });

  static const _unset = Object();
  ConnectBankFlowState copy({
    List<BankInstitution>? aspsps,
    bool? authorizing,
    Object? authorizationOwner = _unset,
    List<BankRecoveryActionResult>? recoveryActions,
    Object? recoveryNotice = _unset,
    List<BankRecoveryActionResult>? recoveryNotices,
    Object? pendingCleanup = _unset,
  }) => ConnectBankFlowState(
    aspsps: aspsps ?? this.aspsps,
    importable: importable,
    connection: connection,
    authorizing: authorizing ?? this.authorizing,
    authorizationOwner: identical(authorizationOwner, _unset)
        ? this.authorizationOwner
        : authorizationOwner as BankAuthorizationOwner?,
    recoveryActions: recoveryActions ?? this.recoveryActions,
    recoveryNotice: identical(recoveryNotice, _unset)
        ? this.recoveryNotice
        : recoveryNotice as BankRecoveryActionResult?,
    recoveryNotices: recoveryNotices ?? this.recoveryNotices,
    pendingCleanup: identical(pendingCleanup, _unset)
        ? this.pendingCleanup
        : pendingCleanup as PendingBankAuthorization?,
    outcomes: outcomes,
    importStatus: importStatus,
    failureScope: failureScope,
  );

  List<BankRecoveryActionResult> get visibleRecoveryNotices =>
      recoveryNotices.isNotEmpty
      ? recoveryNotices
      : recoveryNotice == null
      ? const []
      : [recoveryNotice!];

  int? get connectionId => connection?.id;
  bool get loading => importStatus == BankingImportStatus.loading;
  bool get canImport =>
      !loading &&
      importStatus != BankingImportStatus.terminal &&
      importStatus != BankingImportStatus.pending &&
      importStatus != BankingImportStatus.obsolete &&
      importable.isNotEmpty;
}

typedef BankImportContextCollector =
    Future<Map<String, String>?> Function(List<String> requiredHeaders);

@Riverpod(keepAlive: true)
BankSyncRepository bankSyncRepository(Ref ref) =>
    BankSyncRepository(database: ref.watch(databaseProvider));

@Riverpod(keepAlive: true)
BankSyncService bankSyncService(Ref ref) => BankSyncService(
  accountData: ref.watch(bankAccountDataSourceProvider),
  consent: ref.watch(bankConsentServiceProvider),
  institutions: ref.watch(bankInstitutionDirectoryProvider),
  providerId: ref.watch(bankingServiceProvider).id,
  repository: ref.watch(bankSyncRepositoryProvider),
  readContext: ref.watch(bankAuthorizationContextReaderProvider),
);

void _refreshBankData(Ref ref) {
  ref.invalidate(bankConnectionsProvider);
  ref.invalidate(bankConnectionSyncStatusProvider);
  ref.invalidate(accountsProvider);
  ref.invalidate(transactionsProvider);
  ref.invalidate(lastTransactionsProvider);
  ref.invalidate(dashboardProvider);
  ref.invalidate(statisticsProvider);
}

@Riverpod(keepAlive: true)
class BankConnections extends _$BankConnections {
  @override
  Future<List<BankConnection>> build() async {
    final items = await ref.watch(bankConnectionRepositoryProvider).selectAll();
    return items
        .where(
          (item) =>
              item.status != BankConnectionStatus.revoked &&
              item.status != BankConnectionStatus.disconnected,
        )
        .toList();
  }
}

@riverpod
Future<num?> ebAccountBalance(Ref ref, String accountUid) async {
  final balances = await ref
      .watch(bankAccountDataSourceProvider)
      .getBalances(
        BankingAccountReference(
          providerId: ref.watch(bankingServiceProvider).id,
          remoteId: accountUid,
        ),
      );
  final booked = balances.where(
    (balance) =>
        balance.kind == BankingBalanceKind.closingBooked ||
        balance.kind == BankingBalanceKind.interimBooked,
  );
  if (booked.isEmpty) return null;
  return num.parse(booked.first.amount.decimalAmount);
}

@Riverpod(keepAlive: true)
class ConnectBankFlow extends _$ConnectBankFlow {
  int _operation = 0;
  bool _interactive = false;
  bool _submitting = false;
  BankAuthorizationOwner? _authorizationOperationOwner;
  BankAuthorizationOwner? _cancelledAuthorizationOwner;
  int? _authorizationStartOperation;
  @override
  ConnectBankFlowState build() {
    Future<void>.microtask(() async {
      if (!ref.mounted) return;
      try {
        await refreshAuthorization();
      } catch (_) {
        /* Bootstrap owns pending recovery warnings. */
      }
    });
    return const ConnectBankFlowState();
  }

  int _authorizationRefresh = 0;
  Object? _resumeFlight;
  Object? _cancelRecoveryFlight;
  Future<void>? _authorizationRefreshFuture;

  Future<void> refreshAuthorization() async {
    var pending = _refreshAuthorization();
    _authorizationRefreshFuture = pending;
    while (true) {
      await pending;
      final latest = _authorizationRefreshFuture;
      if (latest == null || identical(latest, pending)) return;
      pending = latest;
    }
  }

  Future<void> _refreshAuthorization() async {
    if (!ref.mounted) return;
    final operation = _operation;
    final refresh = ++_authorizationRefresh;
    final credentials = ref
        .read(enableBankingCredentialsStoreProvider)
        .credentialRevision;
    bool current() =>
        ref.mounted &&
        refresh == _authorizationRefresh &&
        operation == _operation &&
        credentials ==
            ref.read(enableBankingCredentialsStoreProvider).credentialRevision;
    try {
      final lifecycle = ref.read(bankConsentLifecycleServiceProvider);
      final owner = await lifecycle.captureAuthorizationOwner();
      final cleanup =
          owner?.pending != null &&
          await lifecycle.isFinalizedPending(owner!.pending!);
      if (!current()) return;
      state = state.copy(
        authorizationOwner: cleanup ? null : owner,
        pendingCleanup: cleanup ? owner.pending : null,
      );
      ref
          .read(bankRecoveryIssueProvider.notifier)
          .reportPendingCleanup(cleanup ? bankPendingCleanupMessage : null);
    } catch (_) {
      if (current()) {
        ref
            .read(bankRecoveryIssueProvider.notifier)
            .reportPendingCleanup(bankPendingCleanupMessage);
      }
    }
  }

  Future<bool> retryPendingCleanup([PendingBankAuthorization? expected]) async {
    final pending = expected ?? state.pendingCleanup;
    if (pending == null) return true;
    final applied = await ref
        .read(bankConsentLifecycleServiceProvider)
        .retryPendingCleanup(pending);
    if (ref.mounted) {
      if (!applied) {
        ref
            .read(bankRecoveryIssueProvider.notifier)
            .reportPendingCleanup(bankPendingCleanupMessage);
      }
      await refreshAuthorization();
    }
    return applied;
  }

  Future<BankAuthorizationOwner?> captureAuthorizationOwner() async {
    await refreshAuthorization();
    return state.authorizationOwner;
  }

  int get authorizationOperation => _operation;
  bool isAuthorizationOperationCurrent(int expected, int credentials) =>
      ref.mounted &&
      expected == _operation &&
      credentials ==
          ref.read(enableBankingCredentialsStoreProvider).credentialRevision &&
      (_authorizationOperationOwner == null ||
          _cancelledAuthorizationOwner?.sameGeneration(
                _authorizationOperationOwner!,
              ) !=
              true);

  bool isAuthorizationResultCurrent(AuthorizationLaunchResult result) =>
      ref.mounted &&
      result.owner != null &&
      _cancelledAuthorizationOwner?.sameGeneration(result.owner!) != true &&
      state.authorizationOwner?.sameGeneration(result.owner!) == true &&
      ref
          .read(bankConsentLifecycleServiceProvider)
          .isAuthorizationOwnerCurrent(result.owner!);

  Future<void> loadAspsps(String country) async {
    final config = await ref.read(enableBankingSettingsProvider.future);
    if (config == null || !config.supportedCountries.contains(country)) {
      throw const ConnectBankFlowException(
        'This country is not enabled for your application.',
      );
    }
    final institutions = await ref
        .read(bankInstitutionDirectoryProvider)
        .getInstitutions(
          country: country,
          customerType: BankingCustomerType.personal,
        );
    final sorted =
        institutions
            .where(
              (item) =>
                  item.customerTypes.contains(BankingCustomerType.personal),
            )
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    if (ref.mounted) state = state.copy(aspsps: sorted);
  }

  Future<AuthorizationLaunchResult> startConnection(
    BankInstitution institution, {
    BankConnection? reconnecting,
    AuthorizationUrlLauncher? launcher,
  }) async {
    final operation = ++_operation;
    _cancelRecoveryFlight = null;
    _resumeFlight = null;
    final credentials = ref
        .read(enableBankingCredentialsStoreProvider)
        .credentialRevision;
    state = state.copy(authorizing: true);
    BankAuthorizationOwner? owner;
    bool current() =>
        ref.mounted &&
        operation == _operation &&
        owner != null &&
        _cancelledAuthorizationOwner?.sameGeneration(owner!) != true &&
        credentials ==
            ref
                .read(enableBankingCredentialsStoreProvider)
                .credentialRevision &&
        ref
            .read(bankConsentLifecycleServiceProvider)
            .isAuthorizationOwnerCurrent(owner!);
    try {
      final lifecycle = ref.read(bankConsentLifecycleServiceProvider);
      final attempt = await lifecycle.startAuthorization(
        institution,
        reconnectConnectionId: reconnecting?.id,
        onOwner: (value) {
          owner = value;
          if (ref.mounted && operation == _operation) {
            _authorizationOperationOwner = value;
            _authorizationStartOperation = operation;
            state = state.copy(authorizationOwner: value);
          }
        },
      );
      if (!current()) {
        throw const ConnectBankFlowException(bankRecoveryStaleMessage);
      }
      owner = attempt.owner ?? owner;
      state = state.copy(authorizationOwner: owner);
      final result = await lifecycle.launchAuthorization(
        attempt.url,
        launcher: launcher,
      );
      if (!current()) {
        throw const ConnectBankFlowException(bankRecoveryStaleMessage);
      }
      return AuthorizationLaunchResult(
        url: result.url,
        opened: result.opened,
        owner: owner,
      );
    } finally {
      if (ref.mounted && operation == _operation) {
        state = state.copy(authorizing: false);
        await refreshAuthorization();
      }
    }
  }

  Future<AuthorizationLaunchResult?> resumeAuthorization(
    BankAuthorizationOwner expected,
  ) async {
    if (state.authorizing || state.pendingCleanup != null) return null;
    final token = Object();
    _resumeFlight = token;
    final operation = _operation;
    final credentials = ref
        .read(enableBankingCredentialsStoreProvider)
        .credentialRevision;
    bool current() =>
        ref.mounted &&
        identical(_resumeFlight, token) &&
        isAuthorizationOperationCurrent(operation, credentials) &&
        _cancelledAuthorizationOwner?.sameGeneration(expected) != true &&
        ref
            .read(bankConsentLifecycleServiceProvider)
            .isAuthorizationOwnerCurrent(expected);
    state = state.copy(authorizing: true);
    try {
      final result = await ref
          .read(bankConsentLifecycleServiceProvider)
          .resumeAuthorization(expected);
      if (!current()) return null;
      if (!result.opened) {
        _publishRecovery(
          BankRecoveryActionResult(
            kind: BankRecoveryActionKind.resume,
            status: BankRecoveryActionStatus.failed,
            message:
                'Could not open the browser. Try again to resume the same authorization.',
            authorizationOwner: expected,
          ),
          notice: true,
        );
      }
      return result;
    } catch (_) {
      if (current()) {
        _publishRecovery(
          BankRecoveryActionResult(
            kind: BankRecoveryActionKind.resume,
            status: BankRecoveryActionStatus.failed,
            message:
                'Could not open the browser. Try again to resume the same authorization.',
            authorizationOwner: expected,
          ),
          notice: true,
        );
      }
      return null;
    } finally {
      if (ref.mounted && identical(_resumeFlight, token)) {
        state = state.copy(authorizing: false);
        await refreshAuthorization();
      }
    }
  }

  Future<void> reconnect(BankConnection connection) async {
    final institutions = await ref
        .read(bankInstitutionDirectoryProvider)
        .getInstitutions(
          country: connection.institutionCountry,
          customerType: BankingCustomerType.personal,
        );
    final matches = institutions.where(
      (item) =>
          item.providerId == connection.providerId &&
          item.name == connection.institutionName &&
          item.country == connection.institutionCountry,
    );
    if (matches.length != 1) {
      throw const ConnectBankFlowException(
        'This bank is currently unavailable.',
      );
    }
    final credentials = ref
        .read(enableBankingCredentialsStoreProvider)
        .credentialRevision;
    final pending = startConnection(matches.single, reconnecting: connection);
    final operation = _operation;
    try {
      final result = await pending;
      if (!isAuthorizationOperationCurrent(operation, credentials)) return;
      if (!result.opened) {
        throw const ConnectBankFlowException(
          'Could not open the browser. Retry to resume the same authorization.',
        );
      }
    } catch (_) {
      if (isAuthorizationOperationCurrent(operation, credentials)) rethrow;
    }
  }

  Future<bool> _current(
    BankConnection expected,
    int operation,
    int credentials,
  ) async {
    if (!ref.mounted ||
        operation != _operation ||
        credentials !=
            ref
                .read(enableBankingCredentialsStoreProvider)
                .credentialRevision) {
      return false;
    }
    final repository = ref.read(bankConnectionRepositoryProvider);
    final readContext = ref.read(bankAuthorizationContextReaderProvider);
    try {
      final current = await repository.findById(expected.id!);
      final owner = await readContext();
      return ref.mounted &&
          operation == _operation &&
          credentials ==
              ref
                  .read(enableBankingCredentialsStoreProvider)
                  .credentialRevision &&
          current != null &&
          current.sameLifecycle(expected) &&
          owner.applicationId == expected.applicationId &&
          owner.providerId == expected.providerId;
    } catch (_) {
      return false;
    }
  }

  void _importState(
    BankConnection connection,
    List<BankingAccountImportOutcome> outcomes,
    BankingImportStatus status, {
    BankingImportFailureScope? failureScope,
  }) {
    state = ConnectBankFlowState(
      connection: connection,
      aspsps: state.aspsps,
      authorizationOwner: state.authorizationOwner,
      authorizing: state.authorizing,
      recoveryActions: state.recoveryActions,
      recoveryNotice: state.recoveryNotice,
      recoveryNotices: state.recoveryNotices,
      pendingCleanup: state.pendingCleanup,
      outcomes: List.unmodifiable(outcomes),
      importStatus: status,
      failureScope: failureScope,
      importable: List.unmodifiable(
        status == BankingImportStatus.terminal
            ? <BankingAccount>[]
            : outcomes.map((item) => item.account).nonNulls,
      ),
    );
  }

  BankingImportFailureScope _scope(Object error) => switch (error) {
    BankingException(
      failure: BankingFailure.connectionExpired ||
          BankingFailure.connectionRevoked ||
          BankingFailure.connectionClosed,
    ) =>
      BankingImportFailureScope.consent,
    BankingException(
      failure: BankingFailure.authentication || BankingFailure.forbidden,
    ) =>
      BankingImportFailureScope.application,
    _ => BankingImportFailureScope.account,
  };

  Future<void> _terminalTransition(
    BankConnection settled,
    List<BankingAccountImportOutcome> outcomes,
    int operation,
    int credentials,
    BankingFailure? failure,
  ) async {
    if (!await _current(settled, operation, credentials)) return;
    final scope =
        failure == BankingFailure.authentication ||
            failure == BankingFailure.forbidden
        ? BankingImportFailureScope.application
        : BankingImportFailureScope.consent;
    _importState(
      settled,
      [
        for (final outcome in outcomes)
          BankingAccountImportOutcome(
            descriptor: outcome.descriptor,
            status: BankingAccountImportStatus.failed,
            scope: scope,
            code: 'connection_unavailable',
          ),
      ],
      BankingImportStatus.terminal,
      failureScope: scope,
    );
    ref.read(bankRecoveryIssueProvider.notifier).reportImportRecovery(settled);
    ref.invalidate(bankConnectionsProvider);
  }

  Future<void> resumeImport({
    int? connectionId,
    BankingAccountReference? accountReference,
    BankImportContextCollector? collectContext,
  }) async {
    if (_interactive || _submitting) {
      final shown = state.connection;
      if (shown == null) return;
      final current = await ref
          .read(bankConnectionRepositoryProvider)
          .findById(shown.id!);
      if (!ref.mounted || current == null || current.sameLifecycle(shown)) {
        return;
      }
    }
    final interactive = collectContext != null;
    _interactive = interactive;
    final operation = ++_operation;
    final credentials = ref
        .read(enableBankingCredentialsStoreProvider)
        .credentialRevision;
    BankConnection? expected;
    var outcomes = <BankingAccountImportOutcome>[];
    try {
      await recoverBankSessions(ref);
      if (!ref.mounted || operation != _operation) return;
      final staged = await ref
          .read(bankConnectionRepositoryProvider)
          .selectAwaitingImport();
      if (!ref.mounted || operation != _operation) return;
      final candidates = staged.where(
        (item) => connectionId == null || item.id == connectionId,
      );
      if (candidates.isEmpty) return;
      expected = candidates.first;
      if (!await _current(expected, operation, credentials)) return;
      final retained = state.connection?.sameLifecycle(expected) == true
          ? state.outcomes
          : <BankingAccountImportOutcome>[];
      outcomes = retained.toList();
      _importState(expected, outcomes, BankingImportStatus.loading);
      BankConnection? settled;
      BankingFailure? rejection;
      final resumable = await ref
          .read(bankConsentLifecycleServiceProvider)
          .resumeAwaitingImports(
            expectedStaging: expected,
            onRejected: (connection, failure) {
              settled = connection;
              rejection = failure;
            },
          );
      if (!await _current(expected, operation, credentials)) {
        if (settled != null) {
          await _terminalTransition(
            settled!,
            outcomes,
            operation,
            credentials,
            rejection,
          );
        }
        return;
      }
      final matches = resumable.where(
        (item) => item.connection.sameLifecycle(expected!),
      );
      if (matches.isEmpty) {
        _importState(expected, outcomes, BankingImportStatus.pending);
        ref
            .read(bankRecoveryIssueProvider.notifier)
            .reportImportRecovery(expected);
        return;
      }
      final item = matches.first;
      if (item.details.accountDescriptors.every(
        (item) => item.reference == null,
      )) {
        outcomes = [
          for (final descriptor in item.details.accountDescriptors)
            BankingAccountImportOutcome(
              descriptor: descriptor,
              status: BankingAccountImportStatus.unavailable,
            ),
        ];
        final status = bankingImportStatus(outcomes);
        _importState(expected, outcomes, status);
        final issue = ref.read(bankRecoveryIssueProvider.notifier);
        if (status == BankingImportStatus.empty) {
          issue.clearImportRecovery(expected);
        } else {
          issue.reportImportRecovery(expected);
        }
        return;
      }
      final required = await requiredSyncHeaders(expected);
      if (!await _current(expected, operation, credentials)) return;
      Map<String, String> headers = const {};
      if (required.isNotEmpty) {
        if (collectContext == null) {
          _importState(
            expected,
            outcomes,
            BankingImportStatus.manualContextRequired,
          );
          ref
              .read(bankRecoveryIssueProvider.notifier)
              .reportImportRecovery(expected);
          return;
        }
        final values = await collectContext(required);
        if (!await _current(expected, operation, credentials)) return;
        if (values == null) {
          _importState(expected, outcomes, BankingImportStatus.cancelled);
          return;
        }
        headers = BankSyncRequest(
          trigger: BankSyncTrigger.manual,
          psuHeaders: values,
        ).headersFor(required);
      }
      final context = BankingRequestContext(psuHeaders: headers);
      final data = ref.read(bankAccountDataSourceProvider);
      final next = <BankingAccountImportOutcome>[];
      BankingImportFailureScope? terminal;
      for (final descriptor in item.details.accountDescriptors) {
        final reference = descriptor.reference;
        final old = retained.where(
          (outcome) =>
              reference != null && outcome.descriptor.reference == reference,
        );
        if (terminal != null) {
          next.add(
            BankingAccountImportOutcome(
              descriptor: descriptor,
              status: BankingAccountImportStatus.failed,
              scope: terminal,
              code: 'connection_unavailable',
            ),
          );
        } else if (reference == null) {
          next.add(
            BankingAccountImportOutcome(
              descriptor: descriptor,
              status: BankingAccountImportStatus.unavailable,
            ),
          );
        } else if (accountReference != null &&
            reference != accountReference &&
            old.isNotEmpty) {
          next.add(old.first);
        } else {
          try {
            final loaded = await data.getAccount(reference, context: context);
            if (!await _current(expected, operation, credentials)) return;
            if (loaded.reference != reference) {
              throw const FormatException('Account identity mismatch');
            }
            final account = BankingAccount(
              reference: BankingAccountReference(
                providerId: reference.providerId,
                remoteId: reference.remoteId,
                identityKeys: {
                  ...reference.identityKeys,
                  ...loaded.reference.identityKeys,
                },
              ),
              iban: loaded.iban ?? descriptor.iban,
              name: loaded.name ?? descriptor.name,
              details: loaded.details ?? descriptor.details,
              currency: loaded.currency ?? descriptor.currency,
              product: loaded.product ?? descriptor.product,
              accountType: loaded.accountType ?? descriptor.accountType,
              usage: loaded.usage ?? descriptor.usage,
            );
            num? balance;
            String? code;
            try {
              final balances = await data.getBalances(
                reference,
                context: context,
              );
              if (!await _current(expected, operation, credentials)) return;
              final booked = balances.where(
                (item) =>
                    item.kind == BankingBalanceKind.closingBooked ||
                    item.kind == BankingBalanceKind.interimBooked,
              );
              if (booked.isNotEmpty) {
                balance = num.tryParse(booked.first.amount.decimalAmount);
              }
            } catch (error) {
              if (!await _current(expected, operation, credentials)) return;
              if (_scope(error) != BankingImportFailureScope.account) rethrow;
              code = 'balance_unavailable';
            }
            next.add(
              BankingAccountImportOutcome(
                descriptor: descriptor,
                account: account,
                status: BankingAccountImportStatus.available,
                balance: balance,
                code: code,
              ),
            );
          } catch (error) {
            if (!await _current(expected, operation, credentials)) return;
            final scope = _scope(error);
            if (scope != BankingImportFailureScope.account) terminal = scope;
            next.add(
              BankingAccountImportOutcome(
                descriptor: descriptor,
                status: BankingAccountImportStatus.failed,
                scope: scope,
                code: error is BankingException
                    ? error.failure.name
                    : 'account_unavailable',
              ),
            );
          }
        }
      }
      if (!await _current(expected, operation, credentials)) return;
      outcomes = next;
      final status = terminal == null
          ? bankingImportStatus(outcomes)
          : BankingImportStatus.terminal;
      _importState(expected, outcomes, status, failureScope: terminal);
      final issue = ref.read(bankRecoveryIssueProvider.notifier);
      if (status == BankingImportStatus.ready ||
          status == BankingImportStatus.empty) {
        issue.clearImportRecovery(expected);
      } else {
        issue.reportImportRecovery(expected);
      }
      ref.invalidate(bankConnectionsProvider);
    } catch (error) {
      if (expected != null &&
          await _current(expected, operation, credentials)) {
        final scope = _scope(error);
        _importState(
          expected,
          outcomes,
          scope == BankingImportFailureScope.account
              ? BankingImportStatus.allFailed
              : BankingImportStatus.terminal,
          failureScope: scope,
        );
        ref
            .read(bankRecoveryIssueProvider.notifier)
            .reportImportRecovery(expected);
      }
    } finally {
      if (operation == _operation) {
        _interactive = false;
        if (expected != null &&
            ref.mounted &&
            state.loading &&
            state.connection?.sameLifecycle(expected) == true &&
            !await _current(expected, operation, credentials) &&
            ref.mounted &&
            operation == _operation &&
            state.connection?.sameLifecycle(expected) == true) {
          _importState(expected, state.outcomes, BankingImportStatus.obsolete);
        }
      }
      await refreshAuthorization();
    }
  }

  Future<BankSyncSummary> importAccounts(
    List<BankAccountImportSelection> selections, {
    BankImportContextCollector? collectContext,
  }) async {
    if (_submitting) {
      throw const ConnectBankFlowException(
        'The accounts are already being imported.',
      );
    }
    _submitting = true;
    try {
      final operation = _operation;
      final credentials = ref
          .read(enableBankingCredentialsStoreProvider)
          .credentialRevision;
      final expected = selections.isEmpty
          ? null
          : selections.first.expectedStaging;
      final connectionId = expected?.id;
      if (connectionId == null || selections.isEmpty) {
        throw const ConnectBankFlowException(
          'Select accounts from an active connection.',
        );
      }
      if (state.connection == null ||
          !state.connection!.sameLifecycle(expected!) ||
          selections.any(
            (selection) => !selection.expectedStaging.sameLifecycle(expected),
          )) {
        throw const ConnectBankFlowException(
          'The bank connection changed. Reload the accounts before importing.',
        );
      }
      if (selections.any(
        (selection) => !state.importable.any(
          (account) => account.reference == selection.account.reference,
        ),
      )) {
        throw const ConnectBankFlowException(
          'The selected account is not part of this connection.',
        );
      }
      if (!state.canImport ||
          !await _current(expected, operation, credentials)) {
        throw const ConnectBankFlowException(
          'The bank connection changed. Reload the accounts before importing.',
        );
      }
      final required = await requiredSyncHeaders(expected);
      if (!await _current(expected, operation, credentials)) {
        throw const ConnectBankFlowException(
          'The bank connection changed. Reload the accounts before importing.',
        );
      }
      Map<String, String> headers = const {};
      if (required.isNotEmpty) {
        if (collectContext == null) {
          throw const ConnectBankFlowException(
            'Additional details are required to import these accounts.',
          );
        }
        final values = await collectContext(required);
        if (!await _current(expected, operation, credentials)) {
          throw const ConnectBankFlowException(
            'The bank connection changed. Reload the accounts before importing.',
          );
        }
        if (values == null) {
          throw const ConnectBankFlowException(
            'Account loading was cancelled. Try again when you are ready.',
          );
        }
        headers = BankSyncRequest(
          trigger: BankSyncTrigger.manual,
          psuHeaders: values,
        ).headersFor(required);
      }
      final previous = await ref.read(accountsProvider.future);
      if (!ref.mounted ||
          operation != _operation ||
          state.connection == null ||
          !state.connection!.sameLifecycle(expected)) {
        throw const ConnectBankFlowException(
          'The bank connection changed. Reload the accounts before importing.',
        );
      }
      final activated = await ref
          .read(bankConsentLifecycleServiceProvider)
          .activateConnection(connectionId, [
            for (var index = 0; index < selections.length; index++)
              (
                remote: selections[index].account,
                newAccount: BankAccount(
                  name: selections[index].name,
                  symbol: selections[index].symbol,
                  color: selections[index].color,
                  startingValue: 0,
                  active: true,
                  countNetWorth: true,
                  mainAccount: previous.isEmpty && index == 0,
                  order: previous.length + index,
                ),
              ),
          ], expectedStaging: expected);
      if (!ref.mounted ||
          operation != _operation ||
          state.connection == null ||
          !state.connection!.sameLifecycle(expected)) {
        throw const ConnectBankFlowException(
          'The bank connection changed. Reload the accounts before importing.',
        );
      }
      if (!await _current(activated, operation, credentials)) {
        throw const ConnectBankFlowException(
          'The bank connection changed. Reload the accounts before importing.',
        );
      }
      ref
          .read(bankRecoveryIssueProvider.notifier)
          .clearImportRecovery(expected);
      state = ConnectBankFlowState(
        aspsps: state.aspsps,
        authorizationOwner: state.authorizationOwner,
        recoveryActions: state.recoveryActions,
        recoveryNotice: state.recoveryNotice,
        recoveryNotices: state.recoveryNotices,
        pendingCleanup: state.pendingCleanup,
      );
      _refreshBankData(ref);
      return await syncConnectionId(connectionId, psuHeaders: headers);
    } finally {
      _submitting = false;
      await refreshAuthorization();
    }
  }

  Future<BankSyncSummary> syncConnectionId(
    int id, {
    bool initial = false,
    Map<String, String> psuHeaders = const {},
  }) async {
    try {
      return await ref
          .read(bankSyncServiceProvider)
          .syncConnection(
            id,
            request: BankSyncRequest(
              psuHeaders: psuHeaders,
              trigger: initial
                  ? BankSyncTrigger.background
                  : BankSyncTrigger.manual,
            ),
          );
    } finally {
      _refreshBankData(ref);
    }
  }

  Future<List<String>> requiredSyncHeaders(BankConnection connection) async {
    final banks = await ref
        .read(bankInstitutionDirectoryProvider)
        .getInstitutions(
          country: connection.institutionCountry,
          customerType: connection.psuType == 'business'
              ? BankingCustomerType.business
              : BankingCustomerType.personal,
        );
    final bank = banks.singleWhere(
      (item) =>
          item.providerId == connection.providerId &&
          item.name == connection.institutionName &&
          item.country == connection.institutionCountry,
    );
    return bank.requiredPsuHeaders;
  }

  Future<BankSyncSummary> syncConnection(
    BankConnection connection, {
    Map<String, String> psuHeaders = const {},
  }) => syncConnectionId(connection.id!, psuHeaders: psuHeaders);

  final _recoveryFlights = <int, (BankConnection, Object)>{};

  void dismissRecoveryNotice([BankRecoveryActionResult? expected]) {
    final remaining = expected == null
        ? <BankRecoveryActionResult>[]
        : state.visibleRecoveryNotices
              .where((notice) => !identical(notice, expected))
              .toList();
    state = state.copy(
      recoveryNotices: List.unmodifiable(remaining),
      recoveryNotice: remaining.lastOrNull,
    );
  }

  void _publishRecovery(
    BankRecoveryActionResult result, {
    bool notice = false,
  }) {
    if (!ref.mounted) return;
    state = state.copy(
      recoveryActions: List.unmodifiable([
        ...state.recoveryActions.where(
          (item) => result.connection != null
              ? item.connection?.id != result.connection!.id
              : item.kind != BankRecoveryActionKind.cancel,
        ),
        result,
      ]),
      recoveryNotice: notice ? result : state.recoveryNotice,
      recoveryNotices: notice
          ? List.unmodifiable([
              ...state.visibleRecoveryNotices.where(
                (item) => result.connection != null
                    ? item.connection?.id != result.connection!.id
                    : item.authorizationOwner == null ||
                          result.authorizationOwner == null ||
                          !item.authorizationOwner!.sameGeneration(
                            result.authorizationOwner!,
                          ),
              ),
              result,
            ])
          : state.recoveryNotices,
    );
  }

  Future<BankRecoveryActionResult> disconnect(BankConnection connection) =>
      _disconnect(connection, false);
  Future<BankRecoveryActionResult> disconnectLocally(
    BankConnection connection,
  ) => _disconnect(connection, true);

  Future<BankRecoveryActionResult> _disconnect(
    BankConnection expected,
    bool local,
  ) async {
    final kind = local
        ? BankRecoveryActionKind.local
        : BankRecoveryActionKind.revoke;
    PendingBankAuthorization? cleanup;
    BankRecoveryActionResult result(
      BankRecoveryActionStatus status,
      String message,
    ) => BankRecoveryActionResult(
      kind: kind,
      status: status,
      message: message,
      connection: expected,
      pendingCleanup: cleanup,
    );
    final active = _recoveryFlights[expected.id];
    if (active != null && active.$1.sameLifecycle(expected)) {
      return result(BankRecoveryActionStatus.stale, bankRecoveryStaleMessage);
    }
    final repository = ref.read(bankConnectionRepositoryProvider);
    final lifecycle = ref.read(bankConsentLifecycleServiceProvider);
    final readContext = ref.read(bankAuthorizationContextReaderProvider);
    final token = Object();
    _recoveryFlights[expected.id!] = (expected, token);
    bool owned() =>
        ref.mounted && identical(_recoveryFlights[expected.id]?.$2, token);
    _publishRecovery(
      result(
        BankRecoveryActionStatus.running,
        local ? 'Disconnecting locally…' : 'Revoking bank consent…',
      ),
    );
    BankRecoveryActionResult outcome;
    var credentialFailure = false;
    try {
      BankDisconnectFinalization finalization;
      if (local) {
        finalization = await lifecycle.disconnectLocally(expected);
      } else {
        try {
          final context = await readContext();
          credentialFailure =
              context.applicationId != expected.applicationId ||
              context.providerId != expected.providerId;
        } catch (_) {
          credentialFailure = true;
        }
        if (credentialFailure) {
          throw const ConnectBankFlowException(bankRecoveryCredentialsMessage);
        }
        finalization = await lifecycle.revoke(expected);
      }
      cleanup = finalization.pendingCleanup;
      if (owned() && cleanup != null) {
        final projection = state.authorizationOwner?.pending;
        final ownProjection =
            projection?.state == cleanup.state &&
            projection?.authorizationId == cleanup.authorizationId;
        state = state.copy(
          pendingCleanup: cleanup,
          authorizationOwner: ownProjection ? null : state.authorizationOwner,
        );
        ref
            .read(bankRecoveryIssueProvider.notifier)
            .reportPendingCleanup(bankPendingCleanupMessage);
      }
      outcome = result(
        BankRecoveryActionStatus.applied,
        local
            ? 'Bank disconnected locally. Remote consent was not revoked by this action. Manage or revoke it through your bank or Enable Banking.'
            : 'Bank disconnected. Remote access is closed.',
      );
      if (owned() && state.connection?.sameLifecycle(expected) == true) {
        ++_operation;
        _interactive = false;
        state = ConnectBankFlowState(
          aspsps: state.aspsps,
          authorizationOwner: state.authorizationOwner,
          recoveryActions: state.recoveryActions,
          recoveryNotice: state.recoveryNotice,
          recoveryNotices: state.recoveryNotices,
          pendingCleanup: state.pendingCleanup,
        );
      }
    } catch (error) {
      BankConnection? latest;
      var readable = true;
      try {
        latest = await repository.findById(expected.id!);
      } catch (_) {
        readable = false;
      }
      final stale =
          readable &&
          (latest == null ||
              !expected.copy(status: latest.status).sameLifecycle(latest));
      outcome = result(
        stale
            ? BankRecoveryActionStatus.stale
            : BankRecoveryActionStatus.failed,
        stale
            ? bankRecoveryStaleMessage
            : local
            ? 'Could not disconnect the bank locally. Your connection has not been removed. Try again.'
            : credentialFailure
            ? bankRecoveryCredentialsMessage
            : 'Could not confirm that bank consent was revoked. Try again, or disconnect locally. Remote consent may still be active.',
      );
    }
    if (owned()) {
      _recoveryFlights.remove(expected.id);
      _publishRecovery(
        outcome,
        notice:
            outcome.applied || outcome.status == BankRecoveryActionStatus.stale,
      );
      _refreshBankData(ref);
      await refreshAuthorization();
    }
    return outcome;
  }

  Future<BankRecoveryActionResult> cancelAuthorization([
    BankAuthorizationOwner? expected,
  ]) async {
    final lifecycle = ref.read(bankConsentLifecycleServiceProvider);
    if (expected == null) {
      // Preserve the unconditional import/credential-clear contract for existing callers.
      ++_operation;
      _interactive = false;
      _cancelledAuthorizationOwner = _authorizationOperationOwner;
      await lifecycle.cancelAuthorization();
      await refreshAuthorization();
      return const BankRecoveryActionResult(
        kind: BankRecoveryActionKind.cancel,
        status: BankRecoveryActionStatus.applied,
        message: 'Connection attempt cancelled. You can choose another bank.',
      );
    }
    final owner = expected;
    if (lifecycle.isAuthorizationOwnerCurrent(owner)) {
      _cancelledAuthorizationOwner = owner;
      _resumeFlight = null;
      state = state.copy(authorizing: false);
    }
    final token = Object();
    _cancelRecoveryFlight = token;
    BankRecoveryActionResult result(
      BankRecoveryActionStatus status,
      String message,
    ) => BankRecoveryActionResult(
      kind: BankRecoveryActionKind.cancel,
      status: status,
      message: message,
      authorizationOwner: owner,
    );
    var outcome = result(
      BankRecoveryActionStatus.stale,
      bankRecoveryStaleMessage,
    );
    try {
      if (await lifecycle.cancelAuthorizationIfCurrent(owner)) {
        if (ref.mounted &&
            _operation == _authorizationStartOperation &&
            _authorizationOperationOwner?.sameGeneration(owner) == true) {
          ++_operation;
        }
        if (ref.mounted &&
            state.authorizationOwner?.sameGeneration(owner) == true) {
          state = state.copy(authorizing: false, authorizationOwner: null);
        }
        outcome = result(
          BankRecoveryActionStatus.applied,
          'Connection attempt cancelled. You can choose another bank.',
        );
      }
    } catch (_) {
      outcome = result(
        BankRecoveryActionStatus.failed,
        'Could not cancel the connection attempt. Try again before starting another connection.',
      );
    }
    if (ref.mounted && identical(_cancelRecoveryFlight, token)) {
      _publishRecovery(outcome, notice: true);
    }
    await refreshAuthorization();
    return outcome;
  }
}

@Riverpod(keepAlive: true)
Future<void> bankingUiBootstrap(Ref ref) async {
  if (!BankingPlatformSupport.supportsCallback()) return;
  ref.watch(enableBankingSettingsProvider);
  final lifecycle = BankSyncLifecycle(
    service: ref.read(bankSyncServiceProvider),
    prepare: () async {
      try {
        ref.invalidate(bankingCallbackBootstrapProvider);
        await ref.read(bankingCallbackBootstrapProvider.future);
        if (!ref.mounted) return false;
      } catch (_) {
        if (!ref.mounted) return false;
        ref
            .read(bankRecoveryIssueProvider.notifier)
            .reportCallbackRecovery(
              'The bank callback or pending authorization could not be recovered. Retry the connection recovery. Other connected banks can still sync.',
            );
      }
      if (!ref.mounted) return false;
      final credentials = await ref.read(enableBankingSettingsProvider.future);
      if (credentials == null || !ref.mounted) return false;
      final available = await ref
          .read(enableBankingSettingsProvider.notifier)
          .hasCredentials();
      if (!available || !ref.mounted) return false;
      try {
        await ref.read(connectBankFlowProvider.notifier).resumeImport();
      } catch (_) {
        if (ref.mounted) {
          ref
              .read(bankRecoveryIssueProvider.notifier)
              .reportImportRecovery(null);
        }
      }
      return ref.mounted;
    },
    onResult: (result) {
      if (!ref.mounted) return;
      final issue = ref.read(bankRecoveryIssueProvider.notifier);
      if (bankSyncNeedsAttention(result)) {
        issue.reportMessage(bankSyncMessage(result));
      } else {
        issue.clear();
      }
      _refreshBankData(ref);
    },
    onError: (error) {
      if (ref.mounted) {
        ref.read(bankRecoveryIssueProvider.notifier).report(error);
      }
    },
  );
  ref.onDispose(lifecycle.dispose);
  lifecycle.start();
}
