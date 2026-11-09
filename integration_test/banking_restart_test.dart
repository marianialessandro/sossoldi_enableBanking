import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sossoldi/services/banking/lifecycle/bank_deeplink_service.dart';
import 'package:sqflite/sqflite.dart';

import '../test/support/banking_restart_contract.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const phase = String.fromEnvironment(
    'BANKING_QA_RESTART_PHASE',
    defaultValue: 'normal',
  );
  const selected = String.fromEnvironment(
    'BANKING_QA_RESTART_SCENARIO',
    defaultValue: 'knownReceipt',
  );
  const run = String.fromEnvironment('BANKING_QA_RESTART_RUN');
  FlutterSecureStorage storage(String identity) => FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      sharedPreferencesName: 'banking_restart_$identity',
      preferencesKeyPrefix: 'restart_',
    ),
    iOptions: IOSOptions(
      accountName: 'banking-restart-$identity',
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );
  if (phase == 'normal') {
    for (final scenario in BankingRestartScenario.values) {
      testWidgets('RESTART native reopen ${scenario.name}', (tester) async {
        final result = await tester.runAsync(
          () => bankingRestartReopen(
            factory: databaseFactory,
            storage: () => storage('self-contained-${scenario.name}'),
            scenario: scenario,
          ),
        );
        debugPrint('RESTART_EVIDENCE ${jsonEncode(result)}');
      });
    }
    return;
  }
  testWidgets('RESTART coordinated $selected', (tester) async {
    await tester.runAsync(() async {
      expect(['prepare', 'recover', 'cleanup'], contains(phase));
      expect(
        RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(run),
        isTrue,
        reason: 'An explicit isolated QA run identity is required',
      );
      final scenario = BankingRestartScenario.values.byName(selected);
      final directory = Directory(
        '${await databaseFactory.getDatabasesPath()}/banking_restart_qa_$run',
      );
      final fixture = BankingRestartFixture(
        factory: databaseFactory,
        storage: storage(run),
        directory: directory,
        run: run,
        scenario: scenario,
      );
      if (phase == 'cleanup') {
        await bankingRestartCleanup(fixture);
        debugPrint(
          'RESTART_CLEANUP ${jsonEncode({'run': run, 'removed': true})}',
        );
        return;
      }
      final prepared = await fixture.marker.exists();
      if (phase == 'recover' || prepared) {
        final result = await bankingRestartRecover(
          fixture,
          initialSource: scenario == BankingRestartScenario.awaitingCallback
              ? AppLinksUriSource()
              : null,
          requireNewProcess: true,
        );
        const evidence = String.fromEnvironment('BANKING_QA_EVIDENCE');
        if (evidence.isNotEmpty) {
          await Directory(evidence).create(recursive: true);
          await File(
            '$evidence/restart-$run.result.json',
          ).writeAsString(jsonEncode(result), flush: true);
        }
        debugPrint('RESTART_EVIDENCE ${jsonEncode(result)}');
      } else {
        expect(phase, 'prepare');
        var retainedForKill = false;
        try {
          await fixture.open(existing: false);
          await fixture.prepare();
          retainedForKill = true;
          debugPrint('RESTART_READY ${await fixture.marker.readAsString()}');
          // The external QA runner kills this PID after the durable marker; relaunch detects it without resetting the fixture.
          await Completer<void>().future;
        } finally {
          if (!retainedForKill) await fixture.cleanup();
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
