import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:sossoldi/main.dart' as app;
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/providers/accounts_provider.dart';
import 'package:sossoldi/providers/banking_ui_provider.dart';
import 'package:sossoldi/providers/settings_provider.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_api.dart';
import 'package:sossoldi/services/banking/enable_banking/enable_banking_credentials_store.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_result.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_authorization_callback.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_consent_lifecycle_service.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_deeplink_service.dart';
import 'package:sossoldi/services/banking/lifecycle/pending_bank_authorization_store.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_session_recovery_store.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_service.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';

class _Links implements UriLinkSource {
  final controller = StreamController<Uri>.broadcast();
  @override
  Future<Uri?> getInitialUri() async => null;
  @override
  Stream<Uri> get uriStream => controller.stream;
}

class _ObservedLinkSource implements UriLinkSource {
  final UriLinkSource source;
  final receipts = StreamController<Uri>.broadcast();
  int received = 0;
  _ObservedLinkSource(this.source);
  Uri _record(Uri uri) {
    received++;
    receipts.add(uri);
    return uri;
  }

  @override
  Stream<Uri> get uriStream => source.uriStream.map(_record);
  @override
  Future<Uri?> getInitialUri() async {
    final uri = await source.getInitialUri();
    return uri == null ? null : _record(uri);
  }

  Future<void> waitFor(Uri uri) =>
      receipts.stream.firstWhere((value) => value == uri).then((_) {});
}

class _ObservedDeeplinks extends BankDeeplinkService {
  final _ObservedLinkSource observed;
  final completed = StreamController<int>.broadcast();
  int handled = 0;
  _ObservedDeeplinks(this.observed) : super(source: observed);

  @override
  Future<void> start(
    Future<BankCallbackDisposition> Function(BankAuthorizationCallback)
    onCallback, {
    Future<void> Function(Object error)? onError,
  }) => super.start((callback) async {
    final result = await onCallback(callback);
    completed.add(++handled);
    return result;
  }, onError: onError);

  Future<void> waitForHandled(int count) =>
      completed.stream.firstWhere((value) => value >= count).then((_) {});

  @override
  Future<void> dispose() async {
    await super.dispose();
    await observed.receipts.close();
    await completed.close();
  }
}

class _ConsentLauncher extends BankConsentLifecycleService {
  bool browserOpens = false;
  int launchCalls = 0;
  final launchedUrls = <Uri>[];
  _ConsentLauncher(
    Ref ref,
    DateTime now,
    EnableBankingCredentialsStore store,
    EnableBankingApi api,
  ) : super(
        consent: ref.read(bankConsentServiceProvider),
        institutions: ref.read(bankInstitutionDirectoryProvider),
        readContext: ref.read(bankAuthorizationContextReaderProvider),
        pendingStore: ref.read(pendingBankAuthorizationStoreProvider),
        recoveryStore: const SecureBankSessionRecoveryStore(),
        credentialRevision: () => store.credentialRevision,
        cleanupObsoleteConnection: (connection) =>
            cleanupObsoleteEnableBankingConnection(
              store: store,
              api: api,
              connection: connection,
            ),
        connections: ref.read(bankConnectionRepositoryProvider),
        clock: () => now,
      );
  @override
  Future<AuthorizationLaunchResult> launchAuthorization(
    Uri url, {
    AuthorizationUrlLauncher? launcher,
  }) {
    launchCalls++;
    launchedUrls.add(url);
    return super.launchAuthorization(
      url,
      launcher: launcher ?? (_) async => browserOpens,
    );
  }
}

class _Sandbox {
  final DateTime now;
  int authCalls = 0;
  int sessionCalls = 0;
  int transactionCalls = 0;
  int deleteCalls = 0;
  bool offline = false;
  bool discoveryOffline = false;
  _Sandbox(this.now);

  Map<String, Object> get account => {
    'uid': 'qa-account',
    'name': 'QA checking',
    'currency': 'EUR',
    'identification_hash': 'qa-stable',
    'account_id': {'iban': 'IT60X0542811101000000123456'},
  };
  http.Response response(Object body, {int status = 200}) => http.Response(
    jsonEncode(body),
    status,
    headers: {'date': HttpDate.format(now), 'content-type': 'application/json'},
  );

  Future<http.Response> respond(http.Request request) async {
    if (request.url.path == '/application') {
      return response({
        'name': 'UI test application',
        'kid': 'qa-app',
        'environment': 'SANDBOX',
        'active': true,
        'services': ['AIS'],
        'countries': ['IT'],
        'redirect_urls': [kEbRedirectUri, kEbRelayRedirectUri],
      });
    }
    if (request.url.path == '/aspsps') {
      if (discoveryOffline) {
        return response({'error': 'UNAVAILABLE'}, status: 503);
      }
      return response({
        'aspsps': [
          {
            'name': 'QA Bank',
            'country': 'IT',
            'psu_types': ['personal'],
          },
        ],
      });
    }
    if (request.url.path == '/auth') {
      authCalls++;
      return response({
        'authorization_id': 'qa-auth',
        'psu_id_hash': 'qa-psu',
        'url': 'https://consent.example.test/qa',
      });
    }
    if (request.url.path == '/sessions') {
      sessionCalls++;
      return response({
        'session_id': 'qa-session',
        'aspsp': {'name': 'QA Bank', 'country': 'IT'},
        'psu_type': 'personal',
        'access': {
          'valid_until': now.add(const Duration(days: 30)).toIso8601String(),
        },
        'accounts': [account],
      });
    }
    if (request.url.path == '/sessions/qa-session') {
      if (request.method == 'DELETE') {
        deleteCalls++;
        return response({});
      }
      return response({
        'status': 'AUTHORIZED',
        'aspsp': {'name': 'QA Bank', 'country': 'IT'},
        'psu_type': 'personal',
        'created': now.toIso8601String(),
        'access': {
          'valid_until': now.add(const Duration(days: 30)).toIso8601String(),
        },
        'accounts': ['qa-account'],
        'accounts_data': [
          {'uid': 'qa-account', 'identification_hash': 'qa-stable'},
        ],
      });
    }
    if (offline && request.url.path.startsWith('/accounts/')) {
      return response({'error': 'UNAVAILABLE'}, status: 503);
    }
    if (request.url.path.endsWith('/details')) return response(account);
    if (request.url.path.endsWith('/balances')) {
      return response({
        'balances': [
          {
            'name': 'QA booked balance',
            'balance_amount': {'amount': '232.75', 'currency': 'EUR'},
            'balance_type': 'ITBD',
            'last_change_date_time': now
                .subtract(const Duration(hours: 1))
                .toIso8601String(),
            'last_committed_transaction': 'qa-ref',
          },
        ],
      });
    }
    if (request.url.path.endsWith('/transactions')) {
      transactionCalls++;
      return response({
        'transactions': [
          {
            'entry_reference': 'qa-ref',
            'transaction_id': 'qa-transient',
            'transaction_amount': {'amount': '73.14', 'currency': 'EUR'},
            'credit_debit_indicator': 'DBIT',
            'booking_date': now
                .subtract(const Duration(days: 1))
                .toIso8601String()
                .substring(0, 10),
            'status': 'BOOK',
            'remittance_information': ['QA purchase'],
          },
        ],
      });
    }
    throw StateError('Unexpected test endpoint');
  }
}

void main() {
  const nativeCallback = bool.fromEnvironment('BANKING_QA_OS_CALLBACK');
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native UI: credentials, country, authorization retry, callback, import, sync and revoke',
    (tester) async {
      final now = DateTime.utc(2032, 3, 28, 12);
      final sandbox = _Sandbox(now);
      final links = _Links();
      final observed = _ObservedLinkSource(
        nativeCallback ? AppLinksUriSource() : links,
      );
      final deeplinks = _ObservedDeeplinks(observed);
      final callbackFiles = <File>[];
      final client = MockClient(sandbox.respond);
      const store = EnableBankingCredentialsStore();
      final databaseName =
          'banking_ui_qa_${DateTime.now().microsecondsSinceEpoch}.db';
      final database = SossoldiDatabase(dbName: databaseName);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('onboarding_completed', true);
      await store.clear();
      await const SecurePendingBankAuthorizationStore().clear();
      const journal = SecureBankSessionRecoveryStore();
      for (final record in await journal.read()) {
        if (record.applicationId == 'qa-app') {
          await journal.removeIfCurrent(record);
        }
      }
      final journalProbe = BankSessionRecoveryRecord(
        providerId: 'enable_banking',
        applicationId: 'qa-app',
        authorizationId: 'qa-journal-probe',
        phase: BankSessionRecoveryPhase.outcomeUnknown,
        updatedAt: now,
      );
      expect(await journal.upsert(journalProbe), isTrue);
      expect(
        (await journal.read()).any(
          (record) => record.sameAttempt(journalProbe),
        ),
        isTrue,
      );
      expect(await journal.removeIfCurrent(journalProbe), isTrue);
      final api = EnableBankingApi(
        auth: EnableBankingAuth(now: () => now),
        store: store,
        client: client,
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          bankingClockProvider.overrideWithValue(() => now),
          sharedPrefProvider.overrideWithValue(preferences),
          enableBankingApiProvider.overrideWithValue(api),
          bankDeeplinkServiceProvider.overrideWithValue(deeplinks),
          bankConsentLifecycleServiceProvider.overrideWith(
            (ref) => _ConsentLauncher(ref, now, store, api),
          ),
          bankSyncServiceProvider.overrideWith(
            (ref) => BankSyncService(
              accountData: ref.read(bankAccountDataSourceProvider),
              consent: ref.read(bankConsentServiceProvider),
              institutions: ref.read(bankInstitutionDirectoryProvider),
              providerId: 'enable_banking',
              repository: ref.read(bankSyncRepositoryProvider),
              readContext: ref.read(bankAuthorizationContextReaderProvider),
              clock: () => now,
              limits: const BankSyncLimits(manualInterval: Duration.zero),
              sleep: (_) async {},
            ),
          ),
        ],
      );
      addTearDown(() async {
        try {
          await deeplinks.dispose();
          container.dispose();
          client.close();
          await links.controller.close();
          await store.clear();
          await const SecurePendingBankAuthorizationStore().clear();
          for (final record in await journal.read()) {
            if (record.applicationId == 'qa-app') {
              await journal.removeIfCurrent(record);
            }
          }
          expect(
            (await journal.read()).where(
              (record) => record.applicationId == 'qa-app',
            ),
            isEmpty,
          );
          await database.close();
          await sqlite.deleteDatabase(
            '${await sqlite.getDatabasesPath()}/$databaseName',
          );
        } finally {
          for (final file in callbackFiles) {
            if (await file.exists()) await file.delete();
          }
        }
      });

      var androidSurfaceReady = false;
      Future<void> screenshot(String name) async {
        if (Platform.isAndroid && !androidSurfaceReady) {
          await binding.convertFlutterSurfaceToImage();
          await tester.pump();
          androidSurfaceReady = true;
        }
        final bytes = await binding.takeScreenshot(name);
        const directory = String.fromEnvironment('BANKING_QA_EVIDENCE');
        if (directory.isNotEmpty) {
          await File('$directory/$name.png').writeAsBytes(bytes);
        }
      }

      Future<void> until(Finder target) async {
        for (
          var i = 0;
          i < (nativeCallback ? 2400 : 100) && target.evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (target.evaluate().isEmpty) {
          debugPrint(
            'Visible UI labels: ${tester.widgetList<Text>(find.byType(Text)).map((value) => value.data).whereType<String>().join(' | ')}',
          );
          debugPrint(
            'Settings state: ${container.read(enableBankingSettingsProvider).error}',
          );
        }
        expect(target, findsWidgets);
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder target) async {
        await until(target);
        await tester.ensureVisible(target.first);
        await until(target.first.hitTestable());
        await tester.tap(target.first);
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const app.Launcher(),
        ),
      );
      await tester.pumpAndSettle();
      await tap(find.byIcon(Icons.settings));
      await tap(find.text('Bank sync').last);
      await screenshot('setup-preparation');
      await tap(find.text('First-time setup'));
      await tap(find.text('Generate key & certificate'));
      final generated = await store.readSetupDraft();
      expect(generated?.privateKeyPem, isNotNull);
      expect(generated?.certificatePem, contains('BEGIN CERTIFICATE'));
      await screenshot('setup-key-ready');
      Navigator.of(tester.element(find.text('Prepare your key'))).pop();
      await tester.pumpAndSettle();
      await tap(find.text('Bank sync').last);
      await until(find.text('Prepare your key'));
      expect(
        (await store.readSetupDraft())?.privateKeyPem,
        generated!.privateKeyPem,
      );
      expect(
        (await store.readSetupDraft())?.certificatePem,
        generated.certificatePem,
      );
      await tap(find.text('Continue to registration'));
      await screenshot('setup-registration');
      await tap(find.text('Copy return address'));
      expect(
        (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        kEbRelayRedirectUri,
      );
      await tap(find.text('I have my Application ID'));
      await tap(find.text('Verify and continue'));
      await until(find.text('Enter your Enable Banking application ID'));
      await tester.enterText(find.byType(TextField).first, 'qa-app');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await screenshot('setup-verification');
      await tap(find.text('Verify and continue'));
      expect((await store.readCredentials())?.config.appId, 'qa-app');
      expect(await store.readSetupDraft(), isNull);
      await until(find.text('No banks linked yet'));
      await tap(find.byIcon(Icons.add_circle));
      await tap(find.text('Italy'));
      await until(find.text('QA Bank'));
      await tap(find.text('QA Bank'));
      await until(
        find.text(
          'Could not open the browser. Try again to resume the same authorization.',
        ),
      );
      final first = await container
          .read(pendingBankAuthorizationStoreProvider)
          .read();
      expect(first, isNotNull);
      (container.read(bankConsentLifecycleServiceProvider) as _ConsentLauncher)
              .browserOpens =
          true;
      await tap(find.text('Try again').last);
      final launcher =
          container.read(bankConsentLifecycleServiceProvider)
              as _ConsentLauncher;
      expect(launcher.launchCalls, 2);
      expect(launcher.launchedUrls.toSet(), hasLength(1));
      expect(sandbox.authCalls, 1);
      final pending = await container
          .read(pendingBankAuthorizationStoreProvider)
          .read();
      expect(pending!.state, first!.state);
      Future<void> deliver(
        String stage,
        Uri uri, {
        required bool dispatched,
      }) async {
        final receipt = observed.waitFor(uri);
        final handled = dispatched
            ? deeplinks.waitForHandled(deeplinks.handled + 1)
            : null;
        if (nativeCallback) {
          const path = String.fromEnvironment('BANKING_QA_EVIDENCE');
          expect(
            path,
            isNotEmpty,
            reason:
                'OS callback handoff requires a private device-writable evidence directory',
          );
          await Directory(path).create(recursive: true);
          final request = File('$path/callback-$stage.request.json');
          callbackFiles.add(request);
          await request.writeAsString(
            jsonEncode({
              'stage': stage,
              'run': databaseName,
              'url': uri.toString(),
              'pid': pid,
            }),
            flush: true,
          );
        } else {
          links.controller.add(uri);
        }
        await tester.runAsync(
          () => receipt.timeout(const Duration(minutes: 2)),
        );
        if (handled != null) {
          await tester.runAsync(
            () => handled.timeout(const Duration(minutes: 2)),
          );
        }
        await tester.pumpAndSettle();
      }

      Future<void> acknowledge(
        String stage,
        Map<String, Object?> assertions,
      ) async {
        final values = {
          'stage': stage,
          'mode': nativeCallback ? 'os' : 'synthetic-stream',
          'run': databaseName,
          'pid': pid,
          'received': observed.received,
          'handled': deeplinks.handled,
          'session_exchanges': sandbox.sessionCalls,
          ...assertions,
        };
        if (nativeCallback) {
          const path = String.fromEnvironment('BANKING_QA_EVIDENCE');
          final ack = File('$path/callback-$stage.ack.json');
          callbackFiles.add(ack);
          await ack.writeAsString(jsonEncode(values), flush: true);
        }
        debugPrint('CALLBACK_STAGE_ACK ${jsonEncode(values)}');
      }

      final pendingBeforeWrong = pending.toJson();
      await deliver(
        'wrong',
        Uri(
          scheme: 'sossoldi',
          host: 'eb-callback',
          queryParameters: {'state': 'wrong', 'code': 'qa-code'},
        ),
        dispatched: true,
      );
      expect(sandbox.sessionCalls, 0);
      expect(
        (await container.read(pendingBankAuthorizationStoreProvider).read())!
            .toJson(),
        pendingBeforeWrong,
      );
      expect(container.read(bankCallbackResultProvider).error, isNotNull);
      expect(await (await database.database).query('bankAccount'), isEmpty);
      expect(await (await database.database).query('bankConnection'), isEmpty);
      expect(
        await (await database.database).query('bankRemoteTransaction'),
        isEmpty,
      );
      await acknowledge('wrong', {
        'pending_unchanged': true,
        'accounts': 0,
        'rejected': true,
      });
      final callback = Uri(
        scheme: 'sossoldi',
        host: 'eb-callback',
        queryParameters: {'state': pending.state, 'code': 'qa-code'},
      );
      await deliver('valid', callback, dispatched: true);
      await until(find.text('IMPORT SELECTED'));
      expect(sandbox.sessionCalls, 1);
      expect(
        (await container
            .read(bankConnectionRepositoryProvider)
            .selectAwaitingImport()),
        hasLength(1),
      );
      await acknowledge('valid', {'staged': 1, 'import_visible': true});
      expect(find.text('QA checking'), findsWidgets);
      await tester.enterText(find.byType(TextField).first, 'My QA account');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tap(find.text('IMPORT SELECTED'));
      await until(find.text('QA Bank'));
      final accounts = await container.read(accountsProvider.future);
      expect(accounts.single.name, 'My QA account');
      expect(accounts.single.total, closeTo(232.75, 0.001));
      expect(accounts.single.startingValue, closeTo(305.89, 0.001));
      final db = await database.database;
      expect(await db.query('transaction'), hasLength(1));
      expect(await db.query('bankRemoteTransaction'), hasLength(1));
      final handlersBeforeDuplicate = deeplinks.handled;
      await deliver('duplicate', callback, dispatched: false);
      expect(sandbox.sessionCalls, 1);
      expect(deeplinks.handled, handlersBeforeDuplicate);
      expect(await db.query('bankAccount'), hasLength(1));
      expect(await db.query('transaction'), hasLength(1));
      expect(await db.query('bankRemoteTransaction'), hasLength(1));
      expect(find.text('IMPORT SELECTED'), findsNothing);
      await acknowledge('duplicate', {
        'accounts': 1,
        'transactions': 1,
        'ledger': 1,
        'duplicate_suppressed': true,
      });
      await tap(find.byIcon(Icons.refresh));
      await until(find.text('Bank accounts are up to date'));
      expect(await db.query('transaction'), hasLength(1));
      expect(sandbox.transactionCalls, greaterThanOrEqualTo(2));
      await screenshot('banking-native-linked');
      sandbox.discoveryOffline = true;
      await tap(find.byIcon(Icons.refresh));
      await until(find.text('The bank is temporarily unavailable. Try again.'));
      expect(await db.query('transaction'), hasLength(1));
      sandbox.discoveryOffline = false;
      sandbox.offline = true;
      await tap(find.byIcon(Icons.refresh));
      await until(find.text('Sync could not finish. Please retry later.'));
      expect(await db.query('transaction'), hasLength(1));
      expect(
        (await container.read(accountsProvider.future)).single.total,
        closeTo(232.75, 0.001),
      );
      sandbox.offline = false;
      await tap(find.byIcon(Icons.refresh));
      await until(find.text('Bank accounts are up to date'));
      expect(await db.query('transaction'), hasLength(1));
      await tap(find.byIcon(Icons.link_off));
      await tap(find.text('Disconnect and revoke').last);
      await until(find.text('Bank disconnected. Remote access is closed.'));
      await tap(find.text('Dismiss'));
      await until(find.text('No banks linked yet'));
      Navigator.of(tester.element(find.text('No banks linked yet'))).pop();
      await tester.pumpAndSettle();
      await until(find.text('Bank sync is configured'));
      await screenshot('setup-configured');
      await tap(find.text('Replace credentials'));
      await tap(find.text('I already have credentials'));
      await tester.enterText(find.byType(TextField).at(0), 'qa-app');
      await tester.enterText(
        find.byType(TextField).at(1),
        generated.privateKeyPem!,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tap(find.text('Verify and continue'));
      await until(find.text('No banks linked yet'));
      expect(
        (await store.readCredentials())?.privateKeyPem,
        generated.privateKeyPem,
      );

      expect(sandbox.deleteCalls, 1);
      final saved = await container
          .read(bankConnectionRepositoryProvider)
          .selectAll();
      expect(saved.single.status, BankConnectionStatus.revoked);
      expect(
        (await container.read(accountsProvider.future)).single.ebConnectionId,
        isNull,
      );
      expect(await db.query('transaction'), hasLength(1));
      await screenshot('banking-native-disconnected');
      expect(tester.takeException(), isNull);
    },
  );
}
