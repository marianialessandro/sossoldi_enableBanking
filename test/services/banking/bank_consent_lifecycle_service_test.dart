import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/services/banking/bank_authorization_context.dart';
import 'package:sossoldi/services/banking/bank_consent_service.dart';
import 'package:sossoldi/services/banking/bank_institution.dart';
import 'package:sossoldi/services/banking/bank_institution_directory.dart';
import 'package:sossoldi/services/banking/banking_authorization.dart';
import 'package:sossoldi/services/banking/banking_connection.dart';
import 'package:sossoldi/services/banking/banking_exception.dart';
import 'package:sossoldi/services/banking/banking_reference.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_callback.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_coordinator.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_consent_lifecycle_service.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/database/migration_manager.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MemoryPendingStore implements PendingBankAuthorizationStore {
  PendingBankAuthorization? value;
  Completer<void>? saveEntered;
  Completer<void>? saveGate;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<PendingBankAuthorization?> read() async => value;

  @override
  Future<void> save(PendingBankAuthorization pending) async {
    saveEntered?.complete();
    await saveGate?.future;
    value = pending;
  }
}

class _FakeApi implements BankConsentService, BankInstitutionDirectory {
  List<BankInstitution> aspsps = [];
  Completer<void>? entered;
  Completer<void>? startGate;
  Completer<void>? createGate;
  Object? createFailure;
  Object? startFailure;
  Object? deleteFailure;
  Object? getSessionFailure;
  DateTime validUntil = DateTime.utc(2026, 10, 1);
  BankingConnectionStatus sessionStatus = BankingConnectionStatus.active;
  int createCalls = 0;
  int startCalls = 0;
  int deleteCalls = 0;
  DateTime? requestedValidUntil;

  @override
  Future<List<BankInstitution>> getInstitutions({
    String? country,
    BankingCustomerType customerType = BankingCustomerType.personal,
  }) async => aspsps;

  @override
  Future<BankingAuthorization> startAuthorization(
    BankingAuthorizationRequest request,
  ) async {
    startCalls++;
    entered?.complete();
    await startGate?.future;
    if (startFailure case final failure?) throw failure;
    requestedValidUntil = request.validUntil;
    return BankingAuthorization(
      providerId: 'alternative',
      uri: Uri.parse('https://bank.example/authorize'),
      authorizationId: 'authorization-id',
    );
  }

  BankingConnection connection(String id) => BankingConnection(
    reference: BankingConnectionReference(
      providerId: 'alternative',
      remoteId: id,
    ),
    institution: bank(),
    validUntil: validUntil,
    status: sessionStatus,
    accounts: [],
  );

  @override
  Future<BankingConnectionResult> createConnection(String code) async {
    createCalls++;
    entered?.complete();
    await createGate?.future;
    if (createFailure case final failure?) throw failure;
    return BankingConnectionResult(
      connection: connection('session-new'),
      accounts: [],
    );
  }

  @override
  Future<BankingConnection> getConnection(
    BankingConnectionReference reference,
  ) async {
    expect(reference.providerId, 'alternative');
    if (getSessionFailure case final failure?) throw failure;
    return connection(reference.remoteId);
  }

  @override
  Future<void> revokeConnection(BankingConnectionReference reference) async {
    expect(reference.providerId, 'alternative');
    deleteCalls++;
    if (deleteFailure case final failure?) throw failure;
  }
}

BankInstitution bank({
  String name = 'Test Bank',
  String country = 'IT',
  Set<BankingCustomerType> customerTypes = const {BankingCustomerType.personal},
  Duration? maximumConsentDuration,
}) => BankInstitution(
  providerId: 'alternative',
  id: '$country:$name',
  name: name,
  country: country,
  customerTypes: customerTypes,
  maximumConsentDuration: maximumConsentDuration,
);

void main() {
  late Database db;
  late BankConnectionRepository repository;
  BankAuthorizationContext context = const BankAuthorizationContext(
    providerId: 'alternative',
    applicationId: 'app-id',
    redirectUri: 'sossoldi://eb-callback',
  );
  late _MemoryPendingStore pending;
  late _FakeApi api;
  var credentialsRevision = 0;
  final now = DateTime.utc(2026, 9, 1, 12);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    context = const BankAuthorizationContext(
      providerId: 'alternative',
      applicationId: 'app-id',
      redirectUri: 'sossoldi://eb-callback',
    );
    final manager = MigrationManager();
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: manager.latestVersion,
        onCreate: (database, version) => manager.migrate(database, 0, version),
      ),
    );
    repository = BankConnectionRepository.withDatabase(db);
    pending = _MemoryPendingStore();
    api = _FakeApi();
    credentialsRevision = 0;
    api.aspsps = [
      bank(
        name: 'Test Bank',
        country: 'IT',
        customerTypes: {BankingCustomerType.personal},
        maximumConsentDuration: const Duration(seconds: 86400),
      ),
    ];
  });

  tearDown(() => db.close());

  BankConsentLifecycleService service({bool trackCredentials = false}) =>
      BankConsentLifecycleService(
        consent: api,
        institutions: api,
        readContext: () async => context,
        pendingStore: pending,
        connections: repository,
        clock: () => now,
        callbackSupported: () => true,
        credentialRevision: trackCredentials ? () => credentialsRevision : null,
      );

  test('A09 two lifecycle instances share one start and state', () async {
    api.entered = Completer<void>();
    api.startGate = Completer<void>();
    final firstService = service();
    final secondService = service();
    final first = firstService.startAuthorization(bank());
    await api.entered!.future;
    final second = secondService.startAuthorization(bank());
    api.startGate!.complete();
    final results = await Future.wait([first, second]);
    expect(api.startCalls, 1);
    expect(results[0].url, results[1].url);
    expect(results[0].consentValidUntil, results[1].consentValidUntil);
    await secondService.startAuthorization(bank());
    expect(api.startCalls, 1);
  });

  test('A10 Cancel detaches A; its late result cannot overwrite B', () async {
    api.entered = Completer<void>();
    api.startGate = Completer<void>();
    final first = service().startAuthorization(bank());
    final rejected = expectLater(first, throwsA(isA<BankingException>()));
    await api.entered!.future;
    await service().cancelAuthorization();
    final oldGate = api.startGate!;
    api.startGate = null;
    api.entered = null;
    await service().startAuthorization(bank());
    final savedB = pending.value!.toJson();
    oldGate.complete();
    await rejected;
    expect(pending.value!.toJson(), savedB);
    expect(api.startCalls, 2);
  });

  test('Cancel during pending save waits and removes only A', () async {
    pending.saveEntered = Completer<void>();
    pending.saveGate = Completer<void>();
    final first = service().startAuthorization(bank());
    final rejected = expectLater(first, throwsA(isA<BankingException>()));
    await pending.saveEntered!.future;
    final canceled = service().cancelAuthorization();
    pending.saveGate!.complete();
    await Future.wait([rejected, canceled]);
    expect(pending.value, isNull);
  });

  for (final replace in [false, true]) {
    test(
      'A11/A12 obsolete callback ${replace ? 'changed app' : 'Cancel'} cannot stage',
      () async {
        await service().startAuthorization(bank());
        api.entered = Completer<void>();
        api.createGate = Completer<void>();
        final callback = service().completeCallback(
          BankAuthorizationCallback(
            state: pending.value!.state,
            code: 'synthetic',
          ),
        );
        final rejected = expectLater(
          callback,
          throwsA(isA<ObsoleteBankAuthorizationException>()),
        );
        await api.entered!.future;
        if (replace) {
          context = const BankAuthorizationContext(
            providerId: 'alternative',
            applicationId: 'B',
            redirectUri: 'sossoldi://eb-callback',
          );
        } else {
          await service().cancelAuthorization();
        }
        api.createGate!.complete();
        await rejected;
        expect(await repository.selectAwaitingImport(), isEmpty);
        expect(pending.value, isNull);
        if (replace) {
          expect(api.deleteCalls, 0);
          expect(
            pending.coordinator.unresolvedConnections.single.applicationId,
            'app-id',
          );
        } else {
          expect(api.deleteCalls, 1);
        }
      },
    );
  }

  test('duplicate callbacks across instances exchange code once', () async {
    await service().startAuthorization(bank());
    final callback = BankAuthorizationCallback(
      state: pending.value!.state,
      code: 'synthetic',
    );
    final results = await Future.wait([
      service().completeCallback(callback),
      service().completeCallback(callback),
    ]);
    expect(api.createCalls, 1);
    expect(results[0].connection.id, results[1].connection.id);
  });

  test('start failure releases the shared slot for retry', () async {
    api.startFailure = const BankingException(
      providerId: 'alternative',
      failure: BankingFailure.unavailable,
    );
    await expectLater(
      service().startAuthorization(bank()),
      throwsA(isA<BankingException>()),
    );
    api.startFailure = null;
    await service().startAuthorization(bank());
    expect(api.startCalls, 2);
  });

  test(
    'incompatible concurrent bank or app cannot join the shared start',
    () async {
      api.entered = Completer<void>();
      api.startGate = Completer<void>();
      final first = service().startAuthorization(bank());
      await api.entered!.future;
      await expectLater(
        service().startAuthorization(bank(name: 'Other')),
        throwsA(isA<BankingException>()),
      );
      context = const BankAuthorizationContext(
        providerId: 'alternative',
        applicationId: 'B',
        redirectUri: 'sossoldi://eb-callback',
      );
      await expectLater(
        service().startAuthorization(bank()),
        throwsA(isA<BankingException>()),
      );
      context = const BankAuthorizationContext(
        providerId: 'alternative',
        applicationId: 'app-id',
        redirectUri: 'sossoldi://eb-callback',
      );
      api.startGate!.complete();
      await first;
      expect(api.startCalls, 1);
    },
  );

  test('callback A finishing after new pending B leaves B unchanged', () async {
    await service().startAuthorization(bank());
    api.entered = Completer<void>();
    api.createGate = Completer<void>();
    final result = service().completeCallback(
      BankAuthorizationCallback(state: pending.value!.state, code: 'synthetic'),
    );
    final rejected = expectLater(
      result,
      throwsA(isA<ObsoleteBankAuthorizationException>()),
    );
    await api.entered!.future;
    await service().cancelAuthorization();
    api.entered = null;
    await service().startAuthorization(bank());
    final savedB = pending.value!.toJson();
    api.createGate!.complete();
    await rejected;
    expect(pending.value!.toJson(), savedB);
    expect(await repository.selectAwaitingImport(), isEmpty);
  });

  test(
    'same-app credential rotation invalidates a retained lifecycle callback',
    () async {
      final lifecycle = service(trackCredentials: true);
      await lifecycle.startAuthorization(bank());
      api.entered = Completer<void>();
      api.createGate = Completer<void>();
      final result = lifecycle.completeCallback(
        BankAuthorizationCallback(
          state: pending.value!.state,
          code: 'synthetic',
        ),
      );
      final rejected = expectLater(
        result,
        throwsA(isA<ObsoleteBankAuthorizationException>()),
      );
      await api.entered!.future;
      credentialsRevision++;
      api.createGate!.complete();
      await rejected;
      expect(await repository.selectAwaitingImport(), isEmpty);
      expect(api.deleteCalls, 0);
      expect(pending.coordinator.unresolvedConnections, hasLength(1));
    },
  );

  test(
    'Cancel while staged pending save is suspended removes committed staging',
    () async {
      await service().startAuthorization(bank());
      pending.saveEntered = Completer<void>();
      pending.saveGate = Completer<void>();
      final result = service().completeCallback(
        BankAuthorizationCallback(
          state: pending.value!.state,
          code: 'synthetic',
        ),
      );
      final rejected = expectLater(
        result,
        throwsA(isA<ObsoleteBankAuthorizationException>()),
      );
      await pending.saveEntered!.future;
      final canceled = service().cancelAuthorization();
      pending.saveGate!.complete();
      await Future.wait([rejected, canceled]);
      expect(await repository.selectAll(), isEmpty);
      expect(pending.value, isNull);
    },
  );

  test('SQLite staging rolls back when invalidated after insert', () async {
    var checks = 0;
    await expectLater(
      repository.stageConnection(
        providerId: 'alternative',
        authorizationId: 'a',
        applicationId: 'app-id',
        institutionName: 'Test Bank',
        institutionCountry: 'IT',
        remoteConnectionId: 'remote',
        validUntil: now.add(const Duration(days: 1)),
        psuType: 'personal',
        isAuthorizationCurrent: () => ++checks < 4,
      ),
      throwsA(anything),
    );
    expect(checks, 4);
    expect(await repository.selectAll(), isEmpty);
  });

  test('reconnect reloads metadata and clamps requested validity', () async {
    final connection = await repository.insert(
      BankConnection(
        providerId: 'alternative',
        institutionName: 'Test Bank',
        institutionCountry: 'IT',
        applicationId: 'app-id',
        remoteConnectionId: 'old-session',
        validUntil: now.add(const Duration(days: 1)),
        status: BankConnectionStatus.active,
      ),
    );

    final attempt = await service().startAuthorization(
      bank(
        name: 'Test Bank',
        country: 'IT',
        customerTypes: {BankingCustomerType.personal},
        maximumConsentDuration: const Duration(seconds: 7776000),
      ),
      reconnectConnectionId: connection.id,
    );

    expect(api.requestedValidUntil, now.add(const Duration(days: 1)));

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
        BankAuthorizationCallback(code: 'code', state: state),
      );
      final duplicate = await restarted.completeCallback(
        BankAuthorizationCallback(code: 'code', state: state),
      );

      expect(first.connection.status, BankConnectionStatus.awaitingImport);
      expect(first.connection.remoteConnectionId, isNull);
      expect(first.connection.pendingRemoteConnectionId, 'session-new');
      expect(duplicate.connection.id, first.connection.id);
      expect(api.createCalls, 1);
      expect(pending.value?.phase, PendingAuthorizationPhase.connectionStaged);
      expect(
        (await restarted.resumeAwaitingImports()).single.connection.id,
        first.connection.id,
      );
    },
  );

  test('failed staged reconnect keeps the previous session active', () async {
    final connection = await repository.insert(
      BankConnection(
        providerId: 'alternative',
        institutionName: 'Test Bank',
        institutionCountry: 'IT',
        applicationId: 'app-id',
        remoteConnectionId: 'session-old',
        validUntil: now.add(const Duration(days: 1)),
        status: BankConnectionStatus.active,
      ),
    );
    await service().startAuthorization(
      api.aspsps.single,
      reconnectConnectionId: connection.id,
    );
    await service().completeCallback(
      BankAuthorizationCallback(code: 'code', state: pending.value!.state),
    );
    api.sessionStatus = BankingConnectionStatus.expired;

    expect(await service().resumeAwaitingImports(), isEmpty);

    final restored = await repository.selectById(connection.id!);
    expect(restored.status, BankConnectionStatus.active);
    expect(restored.remoteConnectionId, 'session-old');
    expect(restored.pendingRemoteConnectionId, isNull);
    expect(pending.value, isNull);
  });

  test(
    'reauth-required staged import clears pending state and is not resumed again',
    () async {
      await service().startAuthorization(api.aspsps.single);
      final staged = await service().completeCallback(
        BankAuthorizationCallback(code: 'code', state: pending.value!.state),
      );
      api.getSessionFailure = const BankingException(
        providerId: 'alternative',
        failure: BankingFailure.authentication,
      );

      expect(await service().resumeAwaitingImports(), isEmpty);

      final rejected = await repository.selectById(staged.connection.id!);
      expect(rejected.status, BankConnectionStatus.reauthRequired);
      expect(rejected.pendingRemoteConnectionId, isNull);
      expect(rejected.pendingAuthorizationId, isNull);
      expect(rejected.pendingValidUntil, isNull);
      expect(await repository.selectAwaitingImport(), isEmpty);
      expect(pending.value, isNull);
    },
  );

  test(
    'reauth-required staged reconnect keeps the previous session and clears pending state',
    () async {
      final connection = await repository.insert(
        BankConnection(
          providerId: 'alternative',
          institutionName: 'Test Bank',
          institutionCountry: 'IT',
          applicationId: 'app-id',
          remoteConnectionId: 'session-old',
          validUntil: now.add(const Duration(days: 1)),
          status: BankConnectionStatus.active,
        ),
      );
      await service().startAuthorization(
        api.aspsps.single,
        reconnectConnectionId: connection.id,
      );
      await service().completeCallback(
        BankAuthorizationCallback(code: 'code', state: pending.value!.state),
      );
      api.getSessionFailure = const BankingException(
        providerId: 'alternative',
        failure: BankingFailure.forbidden,
      );

      expect(await service().resumeAwaitingImports(), isEmpty);

      final rejected = await repository.selectById(connection.id!);
      expect(rejected.status, BankConnectionStatus.reauthRequired);
      expect(rejected.remoteConnectionId, 'session-old');
      expect(rejected.pendingRemoteConnectionId, isNull);
      expect(rejected.pendingAuthorizationId, isNull);
      expect(rejected.pendingValidUntil, isNull);
      expect(await repository.selectAwaitingImport(), isEmpty);
      expect(pending.value, isNull);
    },
  );

  test(
    'retryable callback failure remains pending and can be retried',
    () async {
      await service().startAuthorization(api.aspsps.single);
      final callback = BankAuthorizationCallback(
        code: 'code',
        state: pending.value!.state,
      );
      api.createFailure = const BankingException(
        providerId: 'alternative',
        failure: BankingFailure.unavailable,
      );

      expect(
        await service().handleCallback(callback),
        BankCallbackDisposition.retryable,
      );
      expect(pending.value, isNotNull);
      api.createFailure = null;
      expect(
        await service().handleCallback(callback),
        BankCallbackDisposition.terminal,
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
        bank(
          name: 'Test Bank',
          country: 'IT',
          customerTypes: {BankingCustomerType.personal},
        ),
      );

      expect(api.requestedValidUntil, now.add(const Duration(days: 90)));
    },
  );

  test('business-only banks are rejected before authorization', () async {
    await expectLater(
      () => service().startAuthorization(
        bank(
          name: 'Corporate Bank',
          country: 'IT',
          customerTypes: {BankingCustomerType.business},
        ),
      ),
      throwsA(
        isA<BankingException>().having(
          (error) => error.failure,
          'kind',
          BankingFailure.rejected,
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
        const BankAuthorizationCallback(code: 'code', state: 'wrong'),
      ),
      throwsA(isA<BankingException>()),
    );
    expect(api.createCalls, 0);
    pending.value = PendingBankAuthorization(
      providerId: 'alternative',
      state: state,
      authorizationId: 'authorization-id',
      authorizationUrl: 'https://bank.example/authorize',
      applicationId: 'app-id',
      institutionName: 'Test Bank',
      institutionCountry: 'IT',
      redirectUri: 'sossoldi://eb-callback',
      expiresAt: now,
      consentValidUntil: now.add(const Duration(days: 1)),
    );
    await expectLater(
      () => service().completeCallback(
        BankAuthorizationCallback(code: 'code', state: state),
      ),
      throwsA(
        isA<BankingException>().having(
          (error) => error.failure,
          'kind',
          BankingFailure.connectionExpired,
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
          providerId: 'alternative',
          institutionName: 'Test Bank',
          institutionCountry: 'IT',
          applicationId: 'app-id',
          remoteConnectionId: 'session',
          validUntil: now.add(const Duration(days: 1)),
          status: BankConnectionStatus.active,
        ),
      );
      for (final kind in const [
        BankingFailure.unavailable,
        BankingFailure.rateLimited,
        BankingFailure.authentication,
        BankingFailure.forbidden,
      ]) {
        api.deleteFailure = BankingException(
          providerId: 'alternative',
          failure: kind,
        );
        await expectLater(
          () => service().revoke(connection),
          throwsA(anything),
        );
        expect(
          (await repository.selectById(connection.id!)).status,
          BankConnectionStatus.revocationPending,
        );
      }

      api.deleteFailure = const BankingException(
        providerId: 'alternative',
        failure: BankingFailure.notFound,
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
        providerId: 'alternative',
        institutionName: 'Test Bank',
        institutionCountry: 'IT',
        applicationId: 'app-id',
        remoteConnectionId: 'session',
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

  for (final reconnect in [false, true]) {
    test(
      'revocation closes staged consent and clears pending import, reconnect=$reconnect',
      () async {
        final connection = await repository.insert(
          BankConnection(
            providerId: 'alternative',
            institutionName: 'Test Bank',
            institutionCountry: 'IT',
            applicationId: 'app-id',
            remoteConnectionId: reconnect ? 'previous-session' : null,
            pendingRemoteConnectionId: 'staged-session',
            pendingAuthorizationId: 'auth-id',
            pendingValidUntil: now.add(const Duration(days: 1)),
            status: BankConnectionStatus.awaitingImport,
          ),
        );
        pending.value = PendingBankAuthorization(
          providerId: 'alternative',
          state: 'state',
          authorizationId: 'auth-id',
          authorizationUrl: 'https://bank.example/authorize',
          applicationId: 'app-id',
          institutionName: 'Test Bank',
          institutionCountry: 'IT',
          redirectUri: context.redirectUri,
          expiresAt: now.add(const Duration(minutes: 10)),
          consentValidUntil: now.add(const Duration(days: 1)),
          stagedConnectionId: connection.id,
        );
        await service().revoke(connection);
        expect(api.deleteCalls, reconnect ? 2 : 1);
        final saved = await repository.selectById(connection.id!);
        expect(saved.status, BankConnectionStatus.revoked);
        expect(saved.pendingRemoteConnectionId, isNull);
        expect(pending.value, isNull);
      },
    );
  }

  test(
    'application auth error does not masquerade as expired session',
    () async {
      final connection = await repository.insert(
        BankConnection(
          providerId: 'alternative',
          institutionName: 'Test Bank',
          institutionCountry: 'IT',
          applicationId: 'app-id',
          remoteConnectionId: 'session',
          validUntil: now.add(const Duration(days: 1)),
          status: BankConnectionStatus.active,
        ),
      );
      api.getSessionFailure = const BankingException(
        providerId: 'alternative',
        failure: BankingFailure.authentication,
      );

      final status = await service().refreshConnectionState(connection);

      expect(status, BankConnectionStatus.reauthRequired);
    },
  );

  test(
    'unsupported platform is rejected before network or pending state',
    () async {
      final unsupported = BankConsentLifecycleService(
        consent: api,
        institutions: api,
        readContext: () async => context,
        pendingStore: pending,
        connections: repository,
        callbackSupported: () => false,
      );

      await expectLater(
        () => unsupported.startAuthorization(api.aspsps.single),
        throwsA(isA<BankingException>()),
      );
      expect(pending.value, isNull);
    },
  );
  for (final changed in [
    const BankAuthorizationContext(
      providerId: 'other',
      applicationId: 'app-id',
      redirectUri: 'sossoldi://eb-callback',
    ),
    const BankAuthorizationContext(
      providerId: 'alternative',
      applicationId: 'rotated',
      redirectUri: 'sossoldi://eb-callback',
    ),
    const BankAuthorizationContext(
      providerId: 'alternative',
      applicationId: 'app-id',
      redirectUri: 'https://example.com/callback',
    ),
  ]) {
    test(
      'pending callback rejects changed context ${changed.providerId}/${changed.applicationId}/${changed.redirectUri}',
      () async {
        await service().startAuthorization(api.aspsps.single);
        final callback = BankAuthorizationCallback(
          code: 'code',
          state: pending.value!.state,
        );
        context = changed;
        await expectLater(
          service().completeCallback(callback),
          throwsA(
            isA<BankingException>().having(
              (error) => error.failure,
              'failure',
              BankingFailure.authentication,
            ),
          ),
        );
        expect(api.createCalls, 0);
        expect(await repository.selectAll(), isEmpty);
      },
    );
  }

  test(
    'foreign institution is rejected before starting authorization',
    () async {
      final foreign = BankInstitution(
        providerId: 'other',
        id: 'bank',
        name: 'Test Bank',
        country: 'IT',
        customerTypes: {BankingCustomerType.personal},
      );
      await expectLater(
        service().startAuthorization(foreign),
        throwsA(isA<BankingException>()),
      );
      expect(api.startCalls, 0);
      expect(pending.value, isNull);
    },
  );

  test(
    'active staged consent with elapsed validity is rejected on resume',
    () async {
      await service().startAuthorization(api.aspsps.single);
      final staged = await service().completeCallback(
        BankAuthorizationCallback(code: 'code', state: pending.value!.state),
      );
      api.validUntil = now;
      expect(await service().resumeAwaitingImports(), isEmpty);
      expect(
        (await repository.selectById(staged.connection.id!)).status,
        BankConnectionStatus.expired,
      );
    },
  );

  test(
    'credential mismatch cannot revoke a connection through another application',
    () async {
      final connection = await repository.insert(
        const BankConnection(
          providerId: 'alternative',
          institutionName: 'Test Bank',
          institutionCountry: 'IT',
          applicationId: 'old-app',
          remoteConnectionId: 'session',
          status: BankConnectionStatus.active,
        ),
      );
      await expectLater(
        service().revoke(connection),
        throwsA(isA<BankingException>()),
      );
      expect(api.deleteCalls, 0);
      expect(
        (await repository.selectById(connection.id!)).remoteConnectionId,
        'session',
      );
    },
  );
}
