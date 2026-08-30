import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../model/bank_account.dart';
import '../model/bank_connection.dart';
import '../services/banking/enable_banking_api.dart';
import '../services/banking/enable_banking_auth.dart';
import '../services/banking/enable_banking_config.dart';
import '../services/banking/enable_banking_credentials_store.dart';
import '../services/banking/enable_banking_deeplink_service.dart';
import '../services/banking/enable_banking_exception.dart';
import '../services/banking/enable_banking_key_generator.dart';
import '../services/banking/enable_banking_sync_service.dart';
import '../services/banking/models/aspsp.dart';
import '../services/banking/models/eb_account.dart';
import '../services/banking/models/eb_balance.dart';
import '../services/banking/models/eb_session.dart';
import '../services/database/repositories/account_repository.dart';
import '../services/database/repositories/bank_connection_repository.dart';
import '../services/database/repositories/transactions_repository.dart';
import 'accounts_provider.dart';
import 'dashboard_provider.dart';
import 'settings_provider.dart';
import 'statistics_provider.dart';
import 'transactions_provider.dart';

part 'banking_provider.g.dart';

const _kDefaultConsentValidity = Duration(days: 90);

String _generateCsrfState({int length = 32}) {
  final random = Random.secure();
  final bytes = List<int>.generate(length, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

class ConnectBankFlowException implements Exception {
  final String message;

  const ConnectBankFlowException(this.message);

  @override
  String toString() => 'ConnectBankFlowException: $message';
}

class BankAccountImportSelection {
  final EbAccount account;
  final String name;
  final String symbol;
  final int color;
  final num startingValue;

  const BankAccountImportSelection({
    required this.account,
    required this.name,
    required this.symbol,
    required this.color,
    this.startingValue = 0,
  });
}

class BankCallbackState {
  final bool processing;
  final String? errorMessage;
  final int? connectionId;

  const BankCallbackState({
    this.processing = false,
    this.errorMessage,
    this.connectionId,
  });
}

class ConnectBankFlowState {
  // Sentinel so copyWith can null out [reconnecting] explicitly.
  static const _unset = Object();

  final String? country;
  final List<Aspsp> aspsps;
  final String? csrfState;
  final bool authorizing;
  final EbSession? session;
  final List<EbAccount> importable;
  final int? connectionId;
  final BankConnection? connection;
  final BankConnection? reconnecting;

  const ConnectBankFlowState({
    this.country,
    this.aspsps = const [],
    this.csrfState,
    this.authorizing = false,
    this.session,
    this.importable = const [],
    this.connectionId,
    this.connection,
    this.reconnecting,
  });

  ConnectBankFlowState copyWith({
    String? country,
    List<Aspsp>? aspsps,
    String? csrfState,
    bool? authorizing,
    EbSession? session,
    List<EbAccount>? importable,
    int? connectionId,
    BankConnection? connection,
    Object? reconnecting = _unset,
  }) => ConnectBankFlowState(
    country: country ?? this.country,
    aspsps: aspsps ?? this.aspsps,
    csrfState: csrfState ?? this.csrfState,
    authorizing: authorizing ?? this.authorizing,
    session: session ?? this.session,
    importable: importable ?? this.importable,
    connectionId: connectionId ?? this.connectionId,
    connection: connection ?? this.connection,
    reconnecting: reconnecting == _unset
        ? this.reconnecting
        : (reconnecting as BankConnection?),
  );
}

@Riverpod(keepAlive: true)
EnableBankingCredentialsStore enableBankingCredentialsStore(Ref ref) =>
    const EnableBankingCredentialsStore();

@Riverpod(keepAlive: true)
EnableBankingAuth enableBankingAuth(Ref ref) => EnableBankingAuth();

@Riverpod(keepAlive: true)
EnableBankingKeyGenerator enableBankingKeyGenerator(Ref ref) =>
    const EnableBankingKeyGenerator();

@Riverpod(keepAlive: true)
EnableBankingApi enableBankingApi(Ref ref) => EnableBankingApi(
  auth: ref.watch(enableBankingAuthProvider),
  store: ref.watch(enableBankingCredentialsStoreProvider),
);

@Riverpod(keepAlive: true)
EnableBankingSyncService enableBankingSyncService(Ref ref) =>
    EnableBankingSyncService(
      api: ref.watch(enableBankingApiProvider),
      accountRepository: ref.watch(accountRepositoryProvider),
      transactionsRepository: ref.watch(transactionsRepositoryProvider),
      bankConnectionRepository: ref.watch(bankConnectionRepositoryProvider),
    );

// Versioned so the balance-reconciliation release performs one immediate
// sync even when the previous build already ran its daily transaction sync.
const _kLastBankSyncCheckKey = 'last_bank_sync_check_v2';

// Runs through Ref (not a standalone function) so it can invalidate the
// same providers as [ConnectBankFlow.syncConnection].
@Riverpod(keepAlive: true)
Future<void> bankAutoSync(Ref ref) async {
  final prefs = ref.read(sharedPrefProvider);
  final lastCheckValue = prefs.getString(_kLastBankSyncCheckKey);
  final lastCheck = lastCheckValue != null
      ? DateTime.parse(lastCheckValue)
      : null;
  if (lastCheck != null && DateTime.now().difference(lastCheck).inDays < 1) {
    return;
  }

  final credentialsStore = ref.read(enableBankingCredentialsStoreProvider);
  if (!await credentialsStore.hasCredentials()) return;

  final bankConnectionRepository = ref.read(bankConnectionRepositoryProvider);
  if ((await bankConnectionRepository.selectActive()).isEmpty) return;

  try {
    await ref.read(enableBankingSyncServiceProvider).syncAll();
  } catch (_) {
    // Don't mark today as checked; retry next start on transient failures.
    return;
  }

  ref.invalidate(bankConnectionsProvider);
  ref.invalidate(accountsProvider);
  ref.invalidate(transactionsProvider);
  ref.invalidate(dashboardProvider);
  ref.invalidate(statisticsProvider);

  await prefs.setString(
    _kLastBankSyncCheckKey,
    DateTime.now().toIso8601String(),
  );
}

@Riverpod(keepAlive: true)
class EnableBankingSettings extends _$EnableBankingSettings {
  @override
  Future<EnableBankingConfig?> build() async {
    final store = ref.watch(enableBankingCredentialsStoreProvider);
    return store.readConfig();
  }

  Future<bool> hasCredentials() async {
    final store = ref.watch(enableBankingCredentialsStoreProvider);
    return store.hasCredentials();
  }

  Future<void> save({
    required String appId,
    required String privateKeyPem,
    required EnableBankingConfig config,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final store = ref.read(enableBankingCredentialsStoreProvider);
      await store.saveCredentials(
        appId: appId,
        privateKeyPem: privateKeyPem,
        config: config,
      );
      ref.read(enableBankingAuthProvider).invalidate();
      return store.readConfig();
    });
  }

  Future<void> clear() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final store = ref.read(enableBankingCredentialsStoreProvider);
      await store.clear();
      ref.read(enableBankingAuthProvider).invalidate();
      return null;
    });
  }

  // Keeps the private key intact so a working key pair isn't discarded.
  Future<void> clearConfig() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final store = ref.read(enableBankingCredentialsStoreProvider);
      await store.clearConfig();
      ref.read(enableBankingAuthProvider).invalidate();
      return null;
    });
  }
}

// Failures return null so account import isn't blocked.
@riverpod
Future<num?> ebAccountBalance(Ref ref, String accountUid) async {
  try {
    final balances = await ref
        .read(enableBankingApiProvider)
        .getBalances(accountUid);
    return preferredEbBalanceAmount(balances);
  } on EnableBankingException {
    return null;
  } on EnableBankingAuthException {
    return null;
  }
}

@Riverpod(keepAlive: true)
EnableBankingDeeplinkService enableBankingDeeplinkService(Ref ref) {
  final service = EnableBankingDeeplinkService();
  ref.onDispose(service.dispose);
  return service;
}

// Kept alive since the OAuth callback can land at any time.
@Riverpod(keepAlive: true)
class BankCallbackHandler extends _$BankCallbackHandler {
  @override
  BankCallbackState build() {
    // Keeps connectBankFlowProvider alive so its CSRF state survives OAuth.
    ref.listen(connectBankFlowProvider, (previous, next) {});
    unawaited(ref.read(enableBankingDeeplinkServiceProvider).start(handle));
    return const BankCallbackState();
  }

  Future<void> handle(EnableBankingCallback callback) async {
    if (!callback.isSuccess) {
      state = BankCallbackState(errorMessage: callback.errorMessage);
      return;
    }

    if (ref.read(connectBankFlowProvider).csrfState == null) {
      state = const BankCallbackState(
        errorMessage: 'No bank connection in progress, please start again',
      );
      return;
    }

    state = const BankCallbackState(processing: true);
    try {
      await ref
          .read(connectBankFlowProvider.notifier)
          .completeConnection(
            code: callback.code!,
            returnedState: callback.state ?? '',
          );
      state = BankCallbackState(
        connectionId: ref.read(connectBankFlowProvider).connectionId,
      );
    } on ConnectBankFlowException catch (e) {
      state = BankCallbackState(errorMessage: e.message);
    } on EnableBankingException catch (e) {
      state = BankCallbackState(
        errorMessage: e.message ?? 'Could not connect to the bank',
      );
    } on EnableBankingAuthException catch (e) {
      state = BankCallbackState(errorMessage: e.message);
    }
  }

  void reset() => state = const BankCallbackState();
}

@Riverpod(keepAlive: true)
class BankConnections extends _$BankConnections {
  // Excludes revoked connections: nothing left to act on.
  @override
  Future<List<BankConnection>> build() async {
    final connections = await ref
        .watch(bankConnectionRepositoryProvider)
        .selectAll();
    return connections
        .where((c) => c.status != BankConnectionStatus.revoked)
        .toList();
  }
}

// autoDispose: a new attempt always starts from an empty state.
@riverpod
class ConnectBankFlow extends _$ConnectBankFlow {
  @override
  ConnectBankFlowState build() => const ConnectBankFlowState();

  Future<void> loadAspsps(String country) async {
    final aspsps = await ref
        .read(enableBankingApiProvider)
        .getAspsps(country: country);
    final sorted = [...aspsps]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    state = state.copyWith(country: country, aspsps: sorted);
  }

  // [reconnecting] makes completeConnection update it, not insert new.
  Future<String> startConnection(
    Aspsp aspsp, {
    BankConnection? reconnecting,
  }) async {
    state = state.copyWith(authorizing: true, reconnecting: reconnecting);
    try {
      final csrfState = _generateCsrfState();
      final maxValidity = aspsp.maximumConsentValidity != null
          ? Duration(seconds: aspsp.maximumConsentValidity!)
          : _kDefaultConsentValidity;
      final config = await ref.read(enableBankingSettingsProvider.future);

      final authorization = await ref
          .read(enableBankingApiProvider)
          .startAuthorization(
            aspspName: aspsp.name,
            aspspCountry: aspsp.country,
            state: csrfState,
            validUntil: DateTime.now().toUtc().add(maxValidity),
            redirectUri: config?.redirectUri ?? kEbRedirectUri,
          );

      state = state.copyWith(csrfState: csrfState);
      return authorization.url;
    } finally {
      state = state.copyWith(authorizing: false);
    }
  }

  Future<void> completeConnection({
    required String code,
    required String returnedState,
  }) async {
    if (state.csrfState == null || returnedState != state.csrfState) {
      throw const ConnectBankFlowException(
        'OAuth callback state does not match the authorization request',
      );
    }

    final session = await ref
        .read(enableBankingApiProvider)
        .createSession(code);
    final bankConnectionRepository = ref.read(bankConnectionRepositoryProvider);

    final reconnecting = state.reconnecting;
    final BankConnection connection;
    if (reconnecting != null) {
      connection = reconnecting.copy(
        sessionId: session.sessionId,
        validUntil: session.validUntil,
        status: BankConnectionStatus.active,
        psuType: session.psuType,
      );
      await bankConnectionRepository.updateItem(connection);
    } else {
      connection = await bankConnectionRepository.insert(
        BankConnection(
          aspspName: session.aspspName,
          aspspCountry: session.aspspCountry,
          sessionId: session.sessionId,
          validUntil: session.validUntil,
          status: BankConnectionStatus.active,
          psuType: session.psuType,
        ),
      );
    }
    ref.invalidate(bankConnectionsProvider);

    state = state.copyWith(
      session: session,
      importable: session.accounts,
      connectionId: connection.id,
      connection: connection,
      reconnecting: null,
    );
  }

  Future<int> importAccounts(
    List<BankAccountImportSelection> selections,
  ) async {
    final connectionId = state.connectionId;
    if (connectionId == null) {
      throw const ConnectBankFlowException(
        'No active bank connection to import accounts into',
      );
    }

    final accountRepository = ref.read(accountRepositoryProvider);
    for (final selection in selections) {
      final existing = await accountRepository.selectByEbUid(
        selection.account.uid,
      );
      if (existing != null) {
        // Reconnect case: relink instead of duplicating.
        await accountRepository.updateItem(
          existing.copy(
            active: true,
            ebConnectionId: connectionId,
            iban: selection.account.iban,
          ),
        );
        continue;
      }

      await accountRepository.insert(
        BankAccount(
          name: selection.name,
          symbol: selection.symbol,
          color: selection.color,
          startingValue: selection.startingValue,
          active: true,
          countNetWorth: true,
          mainAccount: false,
          order: 0,
          ebAccountUid: selection.account.uid,
          ebConnectionId: connectionId,
          iban: selection.account.iban,
        ),
      );
    }

    ref.invalidate(accountsProvider);
    ref.invalidate(dashboardProvider);
    state = state.copyWith(importable: const []);

    final connection = state.connection;
    if (connection == null) return 0;
    try {
      return await syncConnection(connection);
    } on EnableBankingException {
      return 0;
    } on EnableBankingAuthException {
      return 0;
    }
  }

  Future<int> syncConnection(BankConnection connection) async {
    final synced = await ref
        .read(enableBankingSyncServiceProvider)
        .syncConnection(connection);

    ref.invalidate(bankConnectionsProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(transactionsProvider);
    ref.invalidate(dashboardProvider);
    ref.invalidate(statisticsProvider);

    return synced.values.fold<int>(0, (sum, count) => sum + count);
  }

  Future<void> disconnect(BankConnection connection) async {
    try {
      await ref
          .read(enableBankingApiProvider)
          .deleteSession(connection.sessionId);
    } on EnableBankingException {
      // Consent may already be revoked upstream; finalize locally anyway.
    } on EnableBankingAuthException {
      // Credentials may be invalid too; finalize locally anyway.
    }

    // Unlike the remote revoke above, a DB error here isn't caught: it
    // means the disconnect genuinely failed.
    await ref
        .read(bankConnectionRepositoryProvider)
        .finalizeDisconnect(connection.id!);

    ref.invalidate(bankConnectionsProvider);
    ref.invalidate(accountsProvider);
  }
}
