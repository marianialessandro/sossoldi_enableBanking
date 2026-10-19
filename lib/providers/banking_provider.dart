import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;

import '../services/banking/bank_account_data_source.dart' as domain;
import '../services/banking/bank_authorization_context.dart';
import '../services/banking/bank_consent_service.dart' as domain;
import '../services/banking/bank_institution_directory.dart' as domain;
import '../services/banking/banking_provider.dart';
import '../services/banking/enable_banking/enable_banking_config.dart';
import '../services/banking/enable_banking/enable_banking_key_generator.dart';
import '../services/banking/enable_banking/enable_banking_dependencies.dart';
import '../services/banking/enable_banking/enable_banking_errors.dart';
import '../services/banking/enable_banking/enable_banking_provider.dart';
import '../services/banking/lifecycle/bank_authorization_callback.dart';
import '../services/banking/lifecycle/bank_consent_lifecycle_service.dart';
import '../services/banking/lifecycle/bank_deeplink_service.dart';
import '../services/banking/lifecycle/banking_platform_support.dart';
import '../services/banking/lifecycle/pending_bank_authorization_store.dart';
import '../services/banking/lifecycle/bank_session_recovery_store.dart';
import '../services/database/repositories/bank_connection_repository.dart';
import 'banking_ui_provider.dart' show bankRecoveryIssueProvider;

export '../services/banking/enable_banking/enable_banking_dependencies.dart';
export '../services/banking/enable_banking/enable_banking_auth.dart';
export '../services/banking/enable_banking/enable_banking_config.dart';
export '../services/banking/enable_banking/enable_banking_setup_draft.dart';
export '../services/banking/enable_banking/enable_banking_exception.dart';
export '../services/banking/enable_banking/enable_banking_key_generator.dart';

part 'banking_provider.g.dart';

final bankingClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

@Riverpod(keepAlive: true)
BankingProvider bankingService(Ref ref) =>
    EnableBankingProvider(ref.watch(enableBankingApiProvider));

@Riverpod(keepAlive: true)
domain.BankInstitutionDirectory bankInstitutionDirectory(Ref ref) =>
    ref.watch(bankingServiceProvider).institutions;

@Riverpod(keepAlive: true)
domain.BankConsentService bankConsentService(Ref ref) =>
    ref.watch(bankingServiceProvider).consent;

@Riverpod(keepAlive: true)
domain.BankAccountDataSource bankAccountDataSource(Ref ref) =>
    ref.watch(bankingServiceProvider).accountData;

@Riverpod(keepAlive: true)
BankAuthorizationContextReader bankAuthorizationContextReader(Ref ref) {
  final store = ref.watch(enableBankingCredentialsStoreProvider);
  return () => readEnableBankingAuthorizationContext(store);
}

@Riverpod(keepAlive: true)
PendingBankAuthorizationStore pendingBankAuthorizationStore(Ref ref) =>
    const SecurePendingBankAuthorizationStore();

@Riverpod(keepAlive: true)
BankConsentLifecycleService bankConsentLifecycleService(Ref ref) {
  final store = ref.watch(enableBankingCredentialsStoreProvider);
  final api = ref.watch(enableBankingApiProvider);
  return BankConsentLifecycleService(
    consent: ref.watch(bankConsentServiceProvider),
    institutions: ref.watch(bankInstitutionDirectoryProvider),
    readContext: ref.watch(bankAuthorizationContextReaderProvider),
    pendingStore: ref.watch(pendingBankAuthorizationStoreProvider),
    recoveryStore: const SecureBankSessionRecoveryStore(),
    connections: ref.watch(bankConnectionRepositoryProvider),
    clock: ref.watch(bankingClockProvider),
    credentialRevision: () => store.credentialRevision,
    cleanupObsoleteConnection: (connection) =>
        cleanupObsoleteEnableBankingConnection(
          store: store,
          api: api,
          connection: connection,
        ),
  );
}

@Riverpod(keepAlive: true)
BankDeeplinkService bankDeeplinkService(Ref ref) {
  final service = BankDeeplinkService();
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

  Future<BankCallbackDisposition> handle(
    BankAuthorizationCallback callback,
  ) async {
    state = const BankCallbackResultState(processing: true);
    final disposition = await ref
        .read(bankConsentLifecycleServiceProvider)
        .handleCallback(
          callback,
          onStaged: (staged) async {
            if (!ref.mounted) return;
            state = BankCallbackResultState(connectionId: staged.connection.id);
            ref
                .read(bankRecoveryIssueProvider.notifier)
                .reportCallbackRecovery(null);
          },
          onError: reportError,
        );
    if (state.processing) state = const BankCallbackResultState();
    return disposition;
  }

  void reset() => state = const BankCallbackResultState();

  Future<void> reportError(Object error) async {
    if (!ref.mounted) return;
    state = BankCallbackResultState(error: error);
    ref
        .read(bankRecoveryIssueProvider.notifier)
        .reportCallbackRecovery(
          'The bank callback could not be recovered. Retry the connection recovery. Other connected banks can still sync.',
        );
  }
}

@Riverpod(keepAlive: true)
Future<void> bankingCallbackBootstrap(Ref ref) async {
  if (!BankingPlatformSupport.supportsCallback()) return;
  try {
    await recoverBankSessions(ref);
    if (!ref.mounted) return;
    await ref
        .read(bankConsentLifecycleServiceProvider)
        .clearExpiredAuthorization();
    if (!ref.mounted) return;
    var callbackFailed = false;
    await ref
        .watch(bankDeeplinkServiceProvider)
        .start(
          ref.read(bankCallbackResultProvider.notifier).handle,
          onError: (error) async {
            callbackFailed = true;
            if (ref.mounted) {
              await ref
                  .read(bankCallbackResultProvider.notifier)
                  .reportError(error);
            }
          },
        );
    if (ref.mounted &&
        !callbackFailed &&
        ref.read(bankCallbackResultProvider).error == null) {
      ref.read(bankRecoveryIssueProvider.notifier).reportCallbackRecovery(null);
    }
  } catch (error) {
    if (ref.mounted) {
      await ref.read(bankCallbackResultProvider.notifier).reportError(error);
    }
  }
}

Future<void> recoverBankSessions(Ref ref) async {
  try {
    final result = await ref
        .read(bankConsentLifecycleServiceProvider)
        .recoverSessions();
    if (!ref.mounted) return;
    ref
        .read(bankRecoveryIssueProvider.notifier)
        .reportRecovery(
          result.unknown > 0
              ? 'The bank connection outcome is unknown. Check the connection with your bank before starting again.'
              : result.ownerUnavailable > 0
              ? 'Restore the original Enable Banking application credentials to finish connection cleanup.'
              : result.needsAttention
              ? 'Connection cleanup is incomplete. Retry after restoring connectivity and the original application credentials.'
              : null,
        );
  } catch (_) {
    if (ref.mounted) {
      ref
          .read(bankRecoveryIssueProvider.notifier)
          .reportRecovery(
            'Connection recovery could not be checked. Retry before starting another connection.',
          );
    }
  }
}

@Riverpod(keepAlive: true)
class EnableBankingSettings extends _$EnableBankingSettings {
  int _operation = 0;
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
    final store = ref.read(enableBankingCredentialsStoreProvider);
    final operation = ++_operation;
    final invalidation = store.setupInvalidation;
    final revision = store.setupRevision;
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      final previous = await store.readCredentials();
      final saved = await ref
          .read(enableBankingCredentialsServiceProvider)
          .saveVerifiedCredentials(
            appId: appId,
            privateKeyPem: privateKeyPem,
            redirectUri: config.redirectUri,
            defaultCountry: config.defaultCountry,
            expectedSetupRevision: revision,
          );
      try {
        await ref
            .read(bankConnectionRepositoryProvider)
            .markOtherApplicationsReauthRequired(
              saved.appId,
              providerId: enableBankingId,
            );
      } catch (_) {
        if (store.setupInvalidation != invalidation) rethrow;
        if (previous == null) {
          await store.clearCredentialsIfCurrent(revision);
        } else {
          await store.saveCredentials(
            appId: previous.config.appId,
            privateKeyPem: previous.privateKeyPem,
            config: previous.config,
            expectedSetupRevision: revision,
          );
        }
        rethrow;
      }
      await store.clearVerifiedSetupDraft();
      return saved;
    });
    if (operation == _operation) state = result;
    if (operation == _operation && result.hasValue && result.value != null) {
      await recoverBankSessions(ref);
    }
  }

  Future<void> clear() async {
    final operation = ++_operation;
    final store = ref.read(enableBankingCredentialsStoreProvider);
    store.invalidateCredentialCapabilities();
    ref.read(enableBankingAuthProvider).clearCache();
    final canceled = ref
        .read(bankConsentLifecycleServiceProvider)
        .cancelAuthorization();
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      await canceled;
      await ref
          .read(bankConnectionRepositoryProvider)
          .markAllReauthRequired(providerId: enableBankingId);
      await store.clear();
      return null;
    });
    if (operation == _operation) state = result;
  }
}

@Riverpod(keepAlive: true)
EnableBankingKeyGenerator enableBankingKeyGenerator(Ref ref) =>
    const EnableBankingKeyGenerator();
