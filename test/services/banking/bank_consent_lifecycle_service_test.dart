import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/services/banking/bank_consent_lifecycle_service.dart';
import 'package:sossoldi/services/banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking_auth.dart';
import 'package:sossoldi/services/banking/enable_banking_config.dart';
import 'package:sossoldi/services/banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/enable_banking_deeplink_service.dart';
import 'package:sossoldi/services/banking/enable_banking_exception.dart';
import 'package:sossoldi/services/banking/models/aspsp.dart';
import 'package:sossoldi/services/banking/models/eb_auth.dart';
import 'package:sossoldi/services/banking/models/eb_session.dart';
import 'package:sossoldi/services/banking/models/eb_session_details.dart';
import 'package:sossoldi/services/banking/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MemoryPendingStore implements PendingBankAuthorizationStore {
  PendingBankAuthorization? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<PendingBankAuthorization?> read() async => value;

  @override
  Future<void> save(PendingBankAuthorization pending) async => value = pending;
}

class _FakeApi extends EnableBankingApi {
  _FakeApi()
    : super(
        auth: EnableBankingAuth(),
        store: const EnableBankingCredentialsStore(),
      );

  List<Aspsp> aspsps = const [];
  Object? createFailure;
  Object? deleteFailure;
  Object? getSessionFailure;
  EbSessionStatus sessionStatus = EbSessionStatus.authorized;
  int createCalls = 0;
  int startCalls = 0;
  int deleteCalls = 0;
  DateTime? requestedValidUntil;
  String? requestedRedirect;

  @override
  Future<List<Aspsp>> getAspsps({
    String? country,
    String psuType = 'personal',
  }) async => aspsps;

  @override
  Future<EbAuthorization> startAuthorization({
    required String aspspName,
    required String aspspCountry,
    required String state,
    required DateTime validUntil,
    String psuType = 'personal',
    String? language,
    String redirectUri = kEbRedirectUri,
  }) async {
    startCalls++;
    requestedValidUntil = validUntil;
    requestedRedirect = redirectUri;
    return const EbAuthorization(
      url: 'https://bank.example/authorize',
      authorizationId: 'authorization-id',
      psuIdHash: 'psu',
    );
  }

  @override
  Future<EbSession> createSession(String code) async {
    createCalls++;
    if (createFailure case final failure?) throw failure;
    return EbSession(
      sessionId: 'session-new',
      aspspName: 'Test Bank',
      aspspCountry: 'IT',
      validUntil: DateTime.utc(2026, 10, 1),
      psuType: 'personal',
    );
  }

  @override
  Future<EbSessionDetails> getSession(String sessionId) async {
    if (getSessionFailure case final failure?) throw failure;
    return EbSessionDetails(
      status: sessionStatus,
      aspspName: 'Test Bank',
      aspspCountry: 'IT',
      psuType: 'personal',
      validUntil: DateTime.utc(2026, 10, 1),
      created: DateTime.utc(2026, 9, 1),
    );
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    deleteCalls++;
    if (deleteFailure case final failure?) throw failure;
  }
}

void main() {
  late Database db;
  late BankConnectionRepository repository;
  late EnableBankingCredentialsStore credentials;
  late _MemoryPendingStore pending;
  late _FakeApi api;
  final now = DateTime.utc(2026, 9, 1, 12);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    final manager = MigrationManager();
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onCreate: (database, version) => manager.migrate(database, 0, version),
      ),
    );
    repository = BankConnectionRepository.withDatabase(db);
    credentials = const EnableBankingCredentialsStore();
    await credentials.saveCredentials(
      appId: 'app-id',
      privateKeyPem: 'private-key',
      config: const EnableBankingConfig(
        appId: 'app-id',
        redirectUrls: [kEbRedirectUri],
      ),
    );
    pending = _MemoryPendingStore();
    api = _FakeApi();
    api.aspsps = const [
      Aspsp(
        name: 'Test Bank',
        country: 'IT',
        psuTypes: ['personal'],
        maximumConsentValidity: 86400,
      ),
    ];
  });

  tearDown(() => db.close());

  BankConsentLifecycleService service() => BankConsentLifecycleService(
    api: api,
    credentialsStore: credentials,
    pendingStore: pending,
    connections: repository,
    clock: () => now,
    callbackSupported: () => true,
  );

  test('reconnect reloads metadata and clamps requested validity', () async {
    final connection = await repository.insert(
      BankConnection(
        aspspName: 'Test Bank',
        aspspCountry: 'IT',
        applicationId: 'app-id',
        sessionId: 'old-session',
        validUntil: now.add(const Duration(days: 1)),
        status: BankConnectionStatus.active,
      ),
    );

    final attempt = await service().startAuthorization(
      const Aspsp(
        name: 'Test Bank',
        country: 'IT',
        psuTypes: ['personal'],
        maximumConsentValidity: 7776000,
      ),
      reconnectConnectionId: connection.id,
    );

    expect(api.requestedValidUntil, now.add(const Duration(days: 1)));
    expect(api.requestedRedirect, kEbRedirectUri);
    expect(attempt.url.scheme, 'https');
    expect(pending.value?.reconnectConnectionId, connection.id);
  });

  test(
    'cold-start callback stages session and duplicate is idempotent',
    () async {
      await service().startAuthorization(api.aspsps.single);
      final state = pending.value!.state;

      final restarted = service();
      final first = await restarted.completeCallback(
        EnableBankingCallback(code: 'code', state: state),
      );
      final duplicate = await restarted.completeCallback(
        EnableBankingCallback(code: 'code', state: state),
      );

      expect(first.connection.status, BankConnectionStatus.awaitingImport);
      expect(first.connection.sessionId, isNull);
      expect(first.connection.pendingSessionId, 'session-new');
      expect(duplicate.connection.id, first.connection.id);
      expect(api.createCalls, 1);
      expect(pending.value?.phase, PendingAuthorizationPhase.sessionStaged);
      expect(
        (await restarted.resumeAwaitingImports()).single.connection.id,
        first.connection.id,
      );
    },
  );

  test('failed staged reconnect keeps the previous session active', () async {
    final connection = await repository.insert(
      BankConnection(
        aspspName: 'Test Bank',
        aspspCountry: 'IT',
        applicationId: 'app-id',
        sessionId: 'session-old',
        validUntil: now.add(const Duration(days: 1)),
        status: BankConnectionStatus.active,
      ),
    );
    await service().startAuthorization(
      api.aspsps.single,
      reconnectConnectionId: connection.id,
    );
    await service().completeCallback(
      EnableBankingCallback(code: 'code', state: pending.value!.state),
    );
    api.sessionStatus = EbSessionStatus.expired;

    expect(await service().resumeAwaitingImports(), isEmpty);

    final restored = await repository.selectById(connection.id!);
    expect(restored.status, BankConnectionStatus.active);
    expect(restored.sessionId, 'session-old');
    expect(restored.pendingSessionId, isNull);
    expect(pending.value, isNull);
  });

  test(
    'retryable callback failure remains pending and can be retried',
    () async {
      await service().startAuthorization(api.aspsps.single);
      final callback = EnableBankingCallback(
        code: 'code',
        state: pending.value!.state,
      );
      api.createFailure = const EnableBankingException(
        kind: EnableBankingFailureKind.timeout,
      );

      expect(
        await service().handleCallback(callback),
        CallbackDisposition.retryable,
      );
      expect(pending.value, isNotNull);
      api.createFailure = null;
      expect(
        await service().handleCallback(callback),
        CallbackDisposition.terminal,
      );
      expect(api.createCalls, 2);
    },
  );

  test('duplicate authorization start reuses one pending attempt', () async {
    final first = await service().startAuthorization(api.aspsps.single);
    final second = await service().startAuthorization(api.aspsps.single);

    expect(second.url, first.url);
    expect(second.consentValidUntil, first.consentValidUntil);
    expect(api.startCalls, 1);
  });

  test(
    'authorization uses the default validity when no limit exists',
    () async {
      await service().startAuthorization(
        const Aspsp(name: 'Test Bank', country: 'IT', psuTypes: ['personal']),
      );

      expect(api.requestedValidUntil, now.add(const Duration(days: 90)));
    },
  );

  test('business-only banks are rejected before authorization', () async {
    await expectLater(
      () => service().startAuthorization(
        const Aspsp(
          name: 'Corporate Bank',
          country: 'IT',
          psuTypes: ['business'],
        ),
      ),
      throwsA(
        isA<EnableBankingException>().having(
          (error) => error.kind,
          'kind',
          EnableBankingFailureKind.invalidRequest,
        ),
      ),
    );
    expect(api.startCalls, 0);
  });

  test('expired and mismatched callbacks never exchange the code', () async {
    await service().startAuthorization(api.aspsps.single);
    final state = pending.value!.state;

    await expectLater(
      () => service().completeCallback(
        const EnableBankingCallback(code: 'code', state: 'wrong'),
      ),
      throwsA(isA<EnableBankingException>()),
    );
    expect(api.createCalls, 0);
    pending.value = PendingBankAuthorization(
      state: state,
      authorizationId: 'authorization-id',
      authorizationUrl: 'https://bank.example/authorize',
      applicationId: 'app-id',
      aspspName: 'Test Bank',
      aspspCountry: 'IT',
      redirectUri: kEbRedirectUri,
      expiresAt: now,
      consentValidUntil: now.add(const Duration(days: 1)),
    );
    await expectLater(
      () => service().completeCallback(
        EnableBankingCallback(code: 'code', state: state),
      ),
      throwsA(
        isA<EnableBankingException>().having(
          (error) => error.kind,
          'kind',
          EnableBankingFailureKind.sessionExpired,
        ),
      ),
    );
    expect(pending.value, isNull);
  });

  test(
    'failed browser launch preserves retry URL until explicit cancel',
    () async {
      await service().startAuthorization(api.aspsps.single);
      final url = Uri.parse(pending.value!.authorizationUrl);

      final result = await service().launchAuthorization(
        url,
        launcher: (_) async => false,
      );

      expect(result.opened, isFalse);
      expect(result.url, url);
      expect(pending.value, isNotNull);
      await service().cancelAuthorization();
      expect(pending.value, isNull);
    },
  );

  test(
    'retryable revocation stays pending while not-found finalizes',
    () async {
      final connection = await repository.insert(
        BankConnection(
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          applicationId: 'app-id',
          sessionId: 'session',
          validUntil: now.add(const Duration(days: 1)),
          status: BankConnectionStatus.active,
        ),
      );
      for (final kind in const [
        EnableBankingFailureKind.timeout,
        EnableBankingFailureKind.rateLimited,
        EnableBankingFailureKind.server,
        EnableBankingFailureKind.network,
        EnableBankingFailureKind.applicationAuthentication,
      ]) {
        api.deleteFailure = EnableBankingException(kind: kind);
        await expectLater(
          () => service().revoke(connection),
          throwsA(anything),
        );
        expect(
          (await repository.selectById(connection.id!)).status,
          BankConnectionStatus.revocationPending,
        );
      }

      api.deleteFailure = const EnableBankingException(
        kind: EnableBankingFailureKind.notFound,
      );
      await service().revoke(await repository.selectById(connection.id!));
      expect(
        (await repository.selectById(connection.id!)).status,
        BankConnectionStatus.revoked,
      );
    },
  );

  test('confirmed remote revocation finalizes the connection', () async {
    final connection = await repository.insert(
      BankConnection(
        aspspName: 'Test Bank',
        aspspCountry: 'IT',
        applicationId: 'app-id',
        sessionId: 'session',
        validUntil: now.add(const Duration(days: 1)),
        status: BankConnectionStatus.active,
      ),
    );

    await service().revoke(connection);

    expect(api.deleteCalls, 1);
    expect(
      (await repository.selectById(connection.id!)).status,
      BankConnectionStatus.revoked,
    );
  });

  test(
    'application auth error does not masquerade as expired session',
    () async {
      final connection = await repository.insert(
        BankConnection(
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          applicationId: 'app-id',
          sessionId: 'session',
          validUntil: now.add(const Duration(days: 1)),
          status: BankConnectionStatus.active,
        ),
      );
      api.getSessionFailure = const EnableBankingException(
        statusCode: 401,
        kind: EnableBankingFailureKind.applicationAuthentication,
      );

      final status = await service().refreshConnectionState(connection);

      expect(status, BankConnectionStatus.reauthRequired);
    },
  );

  test(
    'unsupported platform is rejected before network or pending state',
    () async {
      final unsupported = BankConsentLifecycleService(
        api: api,
        credentialsStore: credentials,
        pendingStore: pending,
        connections: repository,
        callbackSupported: () => false,
      );

      await expectLater(
        () => unsupported.startAuthorization(api.aspsps.single),
        throwsA(isA<EnableBankingException>()),
      );
      expect(pending.value, isNull);
    },
  );
}
