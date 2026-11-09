import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_result.dart';
import 'package:sossoldi/services/database/repositories/bank_sync_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../support/bank_sync_harness.dart';

void main() {
  sqfliteFfiInit();
  late BankSyncHarness h;
  setUp(() async {
    h = BankSyncHarness(databaseFactoryFfi);
    await h.open();
  });
  tearDown(() => h.close());
  const failure = BankSyncResult(
    accountId: 1,
    status: BankSyncStatus.terminalFailure,
    warnings: ['synthetic_failure'],
  );
  Future<void> reopen() async {
    await h.db.close();
    h.db = await databaseFactoryFfi.openDatabase(h.path);
    h.repository = BankSyncRepository.withDatabase(h.db);
    h.resetService();
  }

  group('AUD repository', () {
    test(
      'same session clock checkpoint noChange supersedes old consent failure',
      () async {
        expect((await h.service.syncAccount(1)).completed, isTrue);
        final old = await h.repository.readContext(1);
        expect(
          (await h.service.syncAccount(1)).status,
          BankSyncStatus.noChange,
        );
        final current = await h.repository.readContext(1);
        expect(current.revision, old.revision + 1);
        expect(current.checkpoint, old.checkpoint);
        expect(current.completedAt, old.completedAt);
        final audit = await h.db.query('bankSyncAudit');
        await reopen();
        await h.repository.markConsentFailure(
          old,
          BankConnectionStatus.expired,
        );
        expect(
          await h.repository.recordFailure(failure, expected: old),
          isFalse,
        );
        expect((await h.db.query('bankConnection')).single['status'], 'ACTIVE');
        expect(await h.db.query('bankSyncAudit'), audit);
      },
    );
    test(
      'missing expected context never overwrites successful audit',
      () async {
        await h.service.syncAccount(1);
        final before = await h.db.query('bankSyncAudit');
        await h.repository.recordFailure(failure);
        expect(await h.db.query('bankSyncAudit'), before);
      },
    );
    for (final mutation in [
      'provider',
      'application',
      'session',
      'uid',
      'link',
      'currency',
      'inactive',
      'removed',
    ]) {
      test('changed $mutation rejects both SQL side effects', () async {
        await h.service.syncAccount(1);
        final expected = await h.repository.readContext(1);
        final audit = await h.db.query('bankSyncAudit');
        switch (mutation) {
          case 'provider':
            await h.db.update('bankConnection', {
              'providerId': 'alternative',
            }, where: 'id = 1');
          case 'application':
            await h.db.update('bankConnection', {
              'applicationId': 'new-app',
            }, where: 'id = 1');
          case 'session':
            await h.db.update('bankConnection', {
              'sessionId': 'new-session',
            }, where: 'id = 1');
          case 'uid':
            await h.db.update('bankAccount', {
              'ebAccountUid': 'new-uid',
            }, where: 'id = 1');
          case 'link':
            final connection =
                Map<String, Object?>.of(
                    (await h.db.query('bankConnection')).single,
                  )
                  ..['id'] = 2
                  ..['sessionId'] = 'linked-session';
            await h.db.insert('bankConnection', connection);
            await h.db.update('bankAccount', {
              'ebConnectionId': 2,
            }, where: 'id = 1');
          case 'currency':
            await h.db.update('bankAccount', {
              'currencyCode': 'USD',
            }, where: 'id = 1');
          case 'inactive':
            await h.db.update('bankAccount', {'active': 0}, where: 'id = 1');
          case 'removed':
            await h.db.delete('bankAccount', where: 'id = 1');
        }
        expect(
          await h.repository.recordFailure(failure, expected: expected),
          isFalse,
        );
        expect(
          await h.repository.markConsentFailure(
            expected,
            BankConnectionStatus.expired,
          ),
          isFalse,
        );
        expect(await h.db.query('bankSyncAudit'), audit);
        expect(
          (await h.db.query(
            'bankConnection',
            where: 'id = 1',
          )).single['status'],
          'ACTIVE',
        );
      });
    }
    test(
      'only the explicitly applied terminal status authorizes failure audit',
      () async {
        await h.service.syncAccount(1);
        final expected = await h.repository.readContext(1);
        expect(
          await h.repository.markConsentFailure(
            expected,
            BankConnectionStatus.expired,
          ),
          isTrue,
        );
        expect(
          await h.repository.recordFailure(failure, expected: expected),
          isFalse,
        );
        expect(
          await h.repository.recordFailure(
            failure,
            expected: expected,
            markedStatus: BankConnectionStatus.reauthRequired,
          ),
          isFalse,
        );
        expect(
          await h.repository.recordFailure(
            failure,
            expected: expected,
            markedStatus: BankConnectionStatus.expired,
          ),
          isTrue,
        );
        expect(
          (await h.repository.latestResults(1)).accounts.single.warnings,
          failure.warnings,
        );
      },
    );
  });
  group('AUD service', () {
    for (final sameSession in [false, true]) {
      test(
        '${sameSession ? 'same-session noChange' : 'A05 renewed session'} late expired preserves audit and status',
        () async {
          expect((await h.service.syncAccount(1)).completed, isTrue);
          final started = await h.repository.readContext(1);
          final entered = Completer<void>();
          final release = Completer<void>();
          h.intercept = (r) async {
            if (r.url.path.endsWith('/details')) {
              entered.complete();
              await release.future;
              return h.response({'error': 'EXPIRED_SESSION'}, status: 401);
            }
            return null;
          };
          final old = h.service.syncAccount(1);
          await entered.future;
          if (!sameSession) {
            await h.db.update('bankConnection', {
              'sessionId': 'new-session',
            }, where: 'id = 1');
          }
          h.intercept = null;
          h.resetService();
          expect(
            (await h.service.syncAccount(1)).status,
            BankSyncStatus.noChange,
          );
          final current = await h.repository.readContext(1);
          expect(current.revision, started.revision + 1);
          expect(current.completedAt, started.completedAt);
          expect(current.checkpoint, started.checkpoint);
          final audit = await h.db.query('bankSyncAudit');
          final state = await h.state();
          release.complete();
          expect((await old).completed, isFalse);
          expect(
            (await h.repository.latestResults(1)).accounts.single.completed,
            isTrue,
          );
          expect(await h.db.query('bankSyncAudit'), audit);
          expect(
            (await h.db.query('bankConnection')).single['status'],
            'ACTIVE',
          );
          expect(await h.state(), state);
          await reopen();
          expect(await h.db.query('bankSyncAudit'), audit);
        },
      );
    }
    for (final error in ['EXPIRED_SESSION', 'REVOKED_SESSION']) {
      test(
        'current $error still records its own audit after marking',
        () async {
          await h.service.syncAccount(1);
          h.intercept = (r) async => r.url.path.endsWith('/details')
              ? h.response({'error': error}, status: 403)
              : null;
          final result = await h.service.syncAccount(1);
          expect(result.completed, isFalse);
          expect(
            (await h.repository.latestResults(1)).accounts.single.warnings,
            result.warnings,
          );
          expect(
            (await h.db.query('bankConnection')).single['status'],
            error == 'EXPIRED_SESSION' ? 'EXPIRED' : 'REAUTH_REQUIRED',
          );
        },
      );
    }
    test(
      'context read failure preserves prior audit and financial data',
      () async {
        await h.service.syncAccount(1);
        final audit = await h.db.query('bankSyncAudit');
        final state = await h.state();
        await h.db.update('bankAccount', {'active': 0}, where: 'id = 1');
        expect((await h.service.syncAccount(1)).completed, isFalse);
        expect(await h.db.query('bankSyncAudit'), audit);
        expect(await h.state(), state);
      },
    );
    test(
      'audit SQL failure reports audit_write_failed and rolls back replacement',
      () async {
        await h.service.syncAccount(1);
        final audit = await h.db.query('bankSyncAudit');
        await h.db.execute(
          "CREATE TRIGGER reject_failure BEFORE INSERT ON bankSyncAudit WHEN NEW.status = 'terminalFailure' BEGIN SELECT RAISE(ABORT, 'synthetic SQL failure'); END",
        );
        h.intercept = (r) async => r.url.path.endsWith('/details')
            ? h.response({'error': 'UNAUTHORIZED'}, status: 401)
            : null;
        expect(
          (await h.service.syncAccount(1)).warnings,
          contains('audit_write_failed'),
        );
        expect(await h.db.query('bankSyncAudit'), audit);
      },
    );
  });
}
