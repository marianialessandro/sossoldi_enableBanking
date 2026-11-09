import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/banking_restart_contract.dart';

class _FailingCleanupStorage extends FlutterSecureStorage {
  int deleteAttempts = 0;
  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deleteAttempts++;
    throw StateError('Controlled QA storage delete failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'RESTART cleanup removes private files when storage deletion fails',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'restart-cleanup-',
      );
      final storage = _FailingCleanupStorage();
      final fixture = BankingRestartFixture(
        factory: databaseFactoryFfi,
        storage: storage,
        directory: directory,
        run: 'cleanup-failure',
        scenario: BankingRestartScenario.knownReceipt,
      );
      try {
        for (final path in [
          fixture.path,
          '${fixture.path}-wal',
          '${fixture.path}-shm',
          fixture.marker.path,
          fixture.callbackHandoff.path,
        ]) {
          await File(path).writeAsString('private synthetic QA artifact');
        }
        await expectLater(
          bankingRestartCleanup(fixture),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Controlled QA storage delete failure',
            ),
          ),
        );
        expect(storage.deleteAttempts, 1);
        expect(await directory.exists(), isFalse);
      } finally {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );
  for (final malformed in [true, false]) {
    test(
      'RESTART recovery initialization failure cleans ${malformed ? 'malformed marker' : 'opened wrong-version database'}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'restart-open-failure-',
        );
        final fixture = BankingRestartFixture(
          factory: databaseFactoryFfi,
          storage: const FlutterSecureStorage(),
          directory: directory,
          run: 'initialization-failure',
          scenario: BankingRestartScenario.knownReceipt,
        );
        try {
          final db = await databaseFactoryFfi.openDatabase(fixture.path);
          await db.setVersion(1);
          await db.close();
          await fixture.marker.writeAsString(
            malformed
                ? '{invalid'
                : jsonEncode({
                    'run': fixture.run,
                    'scenario': fixture.scenario.name,
                  }),
          );
          await fixture.callbackHandoff.writeAsString(
            'private synthetic handoff',
          );
          await fixture.storage.write(
            key: 'private-init-sentinel',
            value: 'synthetic',
          );
          await expectLater(
            bankingRestartRecover(fixture),
            throwsA(malformed ? isA<FormatException>() : isA<TestFailure>()),
          );
          expect(await fixture.storage.readAll(), isEmpty);
          if (!malformed) expect(fixture.db.isOpen, isFalse);
          expect(await directory.exists(), isFalse);
        } finally {
          await fixture.cleanup();
        }
      },
    );
  }
  test(
    'RESTART mock rejects DELETE of independent or unexpected session',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'restart-delete-target-',
      );
      final fixture = BankingRestartFixture(
        factory: databaseFactoryFfi,
        storage: const FlutterSecureStorage(),
        directory: directory,
        run: 'delete-target',
        scenario: BankingRestartScenario.knownReceipt,
      );
      try {
        await fixture.open(existing: false);
        for (final target in ['restart-B-session', 'unexpected-session']) {
          final response = await fixture.client.delete(
            Uri.parse('https://example.test/sessions/$target'),
          );
          expect(response.statusCode, 404);
        }
        final valid = await fixture.client.delete(
          Uri.parse('https://example.test/sessions/restart-known-session'),
        );
        expect(valid.statusCode, 204);
        expect(fixture.deletePaths, [
          '/sessions/restart-B-session',
          '/sessions/unexpected-session',
          '/sessions/restart-known-session',
        ]);
      } finally {
        await fixture.cleanup();
      }
    },
  );
  for (final scenario in BankingRestartScenario.values) {
    test('RESTART host reopen ${scenario.name}', () async {
      final result = await bankingRestartReopen(
        factory: databaseFactoryFfi,
        storage: () => FlutterSecureStorage(
          aOptions: AndroidOptions(
            sharedPreferencesName: 'host_${scenario.name}',
          ),
        ),
        scenario: scenario,
      );
      expect(result['new_process_verified'], isFalse);
      debugPrint('RESTART_EVIDENCE ${jsonEncode(result)}');
    });
  }
}
