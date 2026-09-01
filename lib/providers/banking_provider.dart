import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/banking/enable_banking_api.dart';
import '../services/banking/enable_banking_auth.dart';
import '../services/banking/enable_banking_config.dart';
import '../services/banking/enable_banking_credentials_service.dart';
import '../services/banking/enable_banking_credentials_store.dart';
import '../services/banking/bank_consent_lifecycle_service.dart';
import '../services/banking/enable_banking_deeplink_service.dart';
import '../services/banking/enable_banking_platform_support.dart';
import '../services/banking/pending_bank_authorization_store.dart';
import '../services/database/repositories/bank_connection_repository.dart';

part 'banking_provider.g.dart';

@Riverpod(keepAlive: true)
EnableBankingCredentialsStore enableBankingCredentialsStore(Ref ref) =>
    const EnableBankingCredentialsStore();

@Riverpod(keepAlive: true)
EnableBankingAuth enableBankingAuth(Ref ref) => EnableBankingAuth();

@Riverpod(keepAlive: true)
EnableBankingApi enableBankingApi(Ref ref) => EnableBankingApi(
  auth: ref.watch(enableBankingAuthProvider),
  store: ref.watch(enableBankingCredentialsStoreProvider),
);

@Riverpod(keepAlive: true)
EnableBankingCredentialsService enableBankingCredentialsService(Ref ref) =>
    EnableBankingCredentialsService(
      api: ref.watch(enableBankingApiProvider),
      store: ref.watch(enableBankingCredentialsStoreProvider),
    );

@Riverpod(keepAlive: true)
PendingBankAuthorizationStore pendingBankAuthorizationStore(Ref ref) =>
    const SecurePendingBankAuthorizationStore();

@Riverpod(keepAlive: true)
BankConsentLifecycleService bankConsentLifecycleService(Ref ref) =>
    BankConsentLifecycleService(
      api: ref.watch(enableBankingApiProvider),
      credentialsStore: ref.watch(enableBankingCredentialsStoreProvider),
      pendingStore: ref.watch(pendingBankAuthorizationStoreProvider),
      connections: ref.watch(bankConnectionRepositoryProvider),
    );

@Riverpod(keepAlive: true)
EnableBankingDeeplinkService enableBankingDeeplinkService(Ref ref) {
  final service = EnableBankingDeeplinkService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
}

class BankCallbackResultState {
  final bool processing;
  final int? connectionId;
  final Object? error;

  const BankCallbackResultState({
    this.processing = false,
    this.connectionId,
    this.error,
  });
}

@Riverpod(keepAlive: true)
class BankCallbackResult extends _$BankCallbackResult {
  @override
  BankCallbackResultState build() => const BankCallbackResultState();

  Future<CallbackDisposition> handle(EnableBankingCallback callback) async {
    state = const BankCallbackResultState(processing: true);
    return ref
        .read(bankConsentLifecycleServiceProvider)
        .handleCallback(
          callback,
          onStaged: (session) async {
            state = BankCallbackResultState(
              connectionId: session.connection.id,
            );
          },
          onError: reportError,
        );
  }

  Future<void> reportError(Object error) async {
    state = BankCallbackResultState(error: error);
  }
}

@Riverpod(keepAlive: true)
Future<void> enableBankingCallbackBootstrap(Ref ref) async {
  if (!EnableBankingPlatformSupport.supportsCallback()) return;
  await ref
      .read(bankConsentLifecycleServiceProvider)
      .clearExpiredAuthorization();
  await ref
      .watch(enableBankingDeeplinkServiceProvider)
      .start(
        ref.read(bankCallbackResultProvider.notifier).handle,
        onError: ref.read(bankCallbackResultProvider.notifier).reportError,
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
      final previous = await store.readCredentials();
      final saved = await ref
          .read(enableBankingCredentialsServiceProvider)
          .saveVerifiedCredentials(
            appId: appId,
            privateKeyPem: privateKeyPem,
            redirectUri: config.redirectUri,
            defaultCountry: config.defaultCountry,
          );
      try {
        await ref
            .read(bankConnectionRepositoryProvider)
            .markOtherApplicationsReauthRequired(saved.appId);
      } catch (_) {
        if (previous == null) {
          await store.clear();
        } else {
          await store.saveCredentials(
            appId: previous.config.appId,
            privateKeyPem: previous.privateKeyPem,
            config: previous.config,
          );
        }
        rethrow;
      }
      return saved;
    });
  }

  Future<void> clear() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final store = ref.read(enableBankingCredentialsStoreProvider);
      await ref.read(bankConnectionRepositoryProvider).markAllReauthRequired();
      await store.clear();
      return null;
    });
  }
}
