import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/services/banking/sync/bank_sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../support/bank_sync_harness.dart';

class _ControlledDeadline extends BankSyncDeadline {
  Duration current = Duration.zero;
  final expired = Completer<void>();
  _ControlledDeadline(super.timeout);
  @override
  Duration get elapsed => current;
  void expire() {
    current = timeout;
    expired.complete();
  }

  @override
  Future<T> run<T>(Future<T> Function() action) => Future.any([
    action(),
    expired.future.then<T>(
      (_) => throw TimeoutException('Controlled sync deadline'),
    ),
  ]);
}

void main() {
  sqfliteFfiInit();
  late BankSyncHarness h;
  setUp(() async {
    h = BankSyncHarness(databaseFactoryFfi);
    await h.open();
  });
  tearDown(() => h.close());
  Future<void> financial() async {
    expect((await h.state())['balanceMinor'], '23275');
    expect((await h.state())['openingMinor'], '30589');
    expect(await h.transactions(), hasLength(1));
    expect(
      (await h.db.query('bankRemoteTransaction')).single['amountMinor'],
      '-7314',
    );
    expect(await h.total(), closeTo(232.75, .000001));
  }

  Map<String, Object?> booked({
    String? changed,
    String? reference,
    String amount = '232.75',
  }) => {
    'name': 'Booked',
    'balance_amount': {'amount': amount, 'currency': 'EUR'},
    'balance_type': 'ITBD',
    'last_change_date_time': ?changed,
    'reference_date': ?reference,
    'last_committed_transaction': 'ref-1',
  };
  group('BAL stable', () {
    test(
      'CR01 two booked balances share HTTP acquisition but retain semantic precedence',
      () async {
        h.intercept = (r) async => r.url.path.endsWith('/balances')
            ? h.response({
                'balances': [
                  {
                    ...booked(
                      changed: '2026-09-06T23:00:00Z',
                      amount: '305.89',
                    ),
                    'balance_type': 'CLBD',
                  },
                  booked(changed: '2026-09-07T11:00:00Z'),
                ],
              })
            : null;
        expect((await h.service.syncAccount(1)).completed, isTrue);
        await financial();
        expect((await h.state())['balanceAt'], h.serverTime.toIso8601String());
      },
    );
    test(
      'A02 current reference date keeps unchanged old balance usable',
      () async {
        h.pages = [
          [bankRecord(date: '2026-08-01')],
        ];
        h.intercept = (r) async => r.url.path.endsWith('/balances')
            ? h.response({
                'balances': [
                  booked(
                    changed: '2026-08-01T12:00:00Z',
                    reference: '2026-09-07',
                  ),
                ],
              })
            : null;
        expect((await h.service.syncAccount(1)).completed, isTrue);
        await financial();
      },
    );
    test('A03 same-day reference-only is usable before midnight', () async {
      h.intercept = (r) async => r.url.path.endsWith('/balances')
          ? h.response({
              'balances': [booked(reference: '2026-09-07')],
            })
          : null;
      expect((await h.service.syncAccount(1)).completed, isTrue);
      await financial();
    });
    test('A04 later acquisition requires complete stable reread', () async {
      h.intercept = (r) async => r.url.path.endsWith('/balances')
          ? h.response(
              {
                'balances': [booked(changed: '2026-09-07T12:00:01Z')],
              },
              headers: {'date': 'Mon, 07 Sep 2026 12:00:02 GMT'},
            )
          : null;
      expect((await h.service.syncAccount(1)).completed, isTrue);
      await financial();
      expect(
        h.requests.where((r) => r.url.path.endsWith('/transactions')),
        hasLength(2),
      );
      expect((await h.state())['completedAt'], '2026-09-07T12:00:02.000Z');
    });
  });
  group('BAL changing', () {
    test('balance equal to last page still rereads the earlier page', () async {
      var rounds = 0;
      h.intercept = (r) async {
        if (r.url.path.endsWith('/transactions')) {
          if (r.url.queryParameters['continuation_key'] == null) {
            rounds++;
            return h.response({
              'transactions': [bankRecord()],
              'continuation_key': 'second',
            });
          }
          return h.response(
            {
              'transactions': [bankRecord(reference: 'zero', amount: '0.00')],
            },
            headers: {'date': 'Mon, 07 Sep 2026 12:00:01 GMT'},
          );
        }
        if (r.url.path.endsWith('/balances')) {
          return h.response(
            {
              'balances': [booked(changed: '2026-09-07T11:00:00Z')],
            },
            headers: {'date': 'Mon, 07 Sep 2026 12:00:01 GMT'},
          );
        }
        return null;
      };
      expect((await h.service.syncAccount(1)).completed, isTrue);
      expect(rounds, 2);
      expect((await h.state())['openingMinor'], '30589');
    });
    for (final change in [
      'id',
      'note',
      'value date',
      'add',
      'remove',
      'marker',
    ]) {
      test(
        'fingerprint detects $change despite unchanged amount and anchor',
        () async {
          var round = 0;
          h.intercept = (r) async {
            if (r.url.path.endsWith('/transactions')) {
              round++;
              final first = bankRecord(
                id: change == 'id' && round == 1 ? 'old-id' : 'current-id',
                note: change == 'note' && round == 1
                    ? 'old-note'
                    : 'current-note',
              );
              if (change == 'value date') {
                first['value_date'] = round == 1 ? '2026-09-05' : '2026-09-06';
              }
              final include = change == 'add'
                  ? round > 1
                  : change == 'remove'
                  ? round == 1
                  : change == 'marker';
              return h.response({
                'transactions': [
                  first,
                  if (include) bankRecord(reference: 'zero', amount: '0.00'),
                ],
              });
            }
            if (r.url.path.endsWith('/balances')) {
              final value = booked(changed: '2026-09-07T12:00:01Z');
              if (change == 'marker' && round == 1) {
                value['last_committed_transaction'] = 'zero';
              }
              return h.response(
                {
                  'balances': [value],
                },
                headers: {'date': 'Mon, 07 Sep 2026 12:00:02 GMT'},
              );
            }
            return null;
          };
          expect((await h.service.syncAccount(1)).completed, isTrue);
          expect(round, 3);
          expect((await h.state())['openingMinor'], '30589');
          expect((await h.state())['balanceMinor'], '23275');
        },
      );
    }
    test(
      'canonical list order and advancing HTTP alone do not change fingerprint',
      () async {
        var round = 0;
        h.intercept = (r) async {
          if (r.url.path.endsWith('/transactions')) {
            round++;
            final records = [
              bankRecord(),
              bankRecord(reference: 'zero', amount: '0.00'),
            ];
            return h.response({
              'transactions': round.isEven
                  ? records.reversed.toList()
                  : records,
            });
          }
          if (r.url.path.endsWith('/balances')) {
            return h.response(
              {
                'balances': [booked(changed: '2026-09-07T12:00:01Z')],
              },
              headers: {
                'date': round == 1
                    ? 'Mon, 07 Sep 2026 12:00:02 GMT'
                    : 'Mon, 07 Sep 2026 12:00:03 GMT',
              },
            );
          }
          return null;
        };
        expect((await h.service.syncAccount(1)).completed, isTrue);
        expect(round, 2);
        expect((await h.state())['completedAt'], '2026-09-07T12:00:03.000Z');
        expect((await h.state())['openingMinor'], '30589');
      },
    );
    test(
      'same marker amount and page two corrections must settle as whole cohort',
      () async {
        var rounds = 0;
        h.intercept = (r) async {
          if (r.url.path.endsWith('/transactions')) {
            final page = r.url.queryParameters['continuation_key'];
            if (page == null) {
              rounds++;
              return h.response({
                'transactions': [bankRecord()],
                'continuation_key': 'next',
              });
            }
            return h.response({
              'transactions': [
                bankRecord(
                  reference: 'ref-2',
                  amount: rounds == 1 ? '1.00' : '2.00',
                  note: rounds == 1 ? 'old' : 'corrected',
                ),
              ],
            });
          }
          if (r.url.path.endsWith('/balances')) {
            return h.response(
              {
                'balances': [
                  booked(
                    changed: '2026-09-07T12:00:01Z',
                    amount: rounds == 1 ? '231.75' : '230.75',
                  ),
                ],
              },
              headers: {'date': 'Mon, 07 Sep 2026 12:00:02 GMT'},
            );
          }
          return null;
        };
        expect((await h.service.syncAccount(1)).completed, isTrue);
        expect(rounds, 3);
        expect((await h.state())['openingMinor'], '30589');
        expect((await h.state())['balanceMinor'], '23075');
        expect(await h.transactions(), hasLength(2));
      },
    );
    test('unstable data does not initialize financial tables', () async {
      var round = 0;
      h.intercept = (r) async {
        if (r.url.path.endsWith('/transactions')) round++;
        if (r.url.path.endsWith('/balances')) {
          return h.response(
            {
              'balances': [
                booked(changed: '2026-09-07T12:00:01Z', amount: '23$round.75'),
              ],
            },
            headers: {'date': 'Mon, 07 Sep 2026 12:00:02 GMT'},
          );
        }
        return null;
      };
      final result = await h.service.syncAccount(1);
      expect(result.warnings, contains('balance_snapshot_unstable'));
      expect(round, 4);
      expect(await h.transactions(), isEmpty);
      expect(await h.db.query('bankRemoteTransaction'), isEmpty);
      expect(await h.db.query('bankSyncState'), isEmpty);
      expect((await h.db.query('bankAccount')).single['startingValue'], 0);
    });
  });
  group('BAL budget', () {
    test(
      'one deadline protects initialized data across additional collection',
      () async {
        await h.service.syncAccount(1);
        final state = await h.state();
        final ledger = await h.db.query('bankRemoteTransaction');
        final accounts = await h.db.query('bankAccount');
        final transactions = await h.transactions();
        final deadline = _ControlledDeadline(const Duration(minutes: 3));
        var deadlineStarts = 0;
        h.resetService(
          limits: const BankSyncLimits(
            manualInterval: Duration.zero,
            backgroundInterval: Duration.zero,
          ),
          deadline: (timeout) {
            expect(timeout, deadline.timeout);
            deadlineStarts++;
            return deadline;
          },
        );
        var rounds = 0;
        final entered = Completer<void>();
        final release = Completer<void>();
        h.intercept = (r) async {
          if (r.url.path.endsWith('/transactions')) {
            rounds++;
            if (rounds == 2) {
              entered.complete();
              await release.future;
            }
          }
          if (r.url.path.endsWith('/balances')) {
            return h.response(
              {
                'balances': [booked(changed: '2026-09-07T12:00:01Z')],
              },
              headers: {'date': 'Mon, 07 Sep 2026 12:00:02 GMT'},
            );
          }
          return null;
        };
        final running = h.service.syncAccount(1);
        await entered.future;
        deadline.expire();
        final result = await running;
        release.complete();
        expect(result.warnings, contains('operation_timeout'));
        expect(entered.isCompleted, isTrue, reason: result.warnings.toString());
        expect(rounds, 2);
        expect(deadlineStarts, 1);
        expect(await h.state(), state);
        expect(await h.db.query('bankRemoteTransaction'), ledger);
        expect(await h.db.query('bankAccount'), accounts);
        expect(await h.transactions(), transactions);
      },
    );
    test(
      'zero retries allows one collection and never accepts discordance',
      () async {
        h.resetService(limits: const BankSyncLimits(retries: 0));
        h.intercept = (r) async => r.url.path.endsWith('/balances')
            ? h.response(
                {
                  'balances': [booked(changed: '2026-09-07T12:00:01Z')],
                },
                headers: {'date': 'Mon, 07 Sep 2026 12:00:02 GMT'},
              )
            : null;
        expect(
          (await h.service.syncAccount(1)).warnings,
          contains('balance_snapshot_unstable'),
        );
        expect(
          h.requests.where((r) => r.url.path.endsWith('/transactions')),
          hasLength(1),
        );
        expect(await h.transactions(), isEmpty);
      },
    );
    test(
      'record budget spans rounds and a subsequent valid attempt recovers',
      () async {
        h.resetService(limits: const BankSyncLimits(records: 1));
        h.intercept = (r) async => r.url.path.endsWith('/balances')
            ? h.response(
                {
                  'balances': [booked(changed: '2026-09-07T12:00:01Z')],
                },
                headers: {'date': 'Mon, 07 Sep 2026 12:00:02 GMT'},
              )
            : null;
        expect(
          (await h.service.syncAccount(1)).warnings,
          contains('record_limit'),
        );
        expect(await h.db.query('bankSyncState'), isEmpty);
        expect(await h.transactions(), isEmpty);
        h.intercept = null;
        h.resetService();
        expect((await h.service.syncAccount(1)).completed, isTrue);
        await financial();
      },
    );
    test(
      'full interval rejects backward jump hidden by first timestamp',
      () async {
        h.pages = [
          [bankRecord()],
          [bankRecord(reference: 'two')],
          [bankRecord(reference: 'three')],
        ];
        h.intercept = (r) async {
          if (!r.url.path.endsWith('/transactions')) return null;
          final page = int.parse(
            r.url.queryParameters['continuation_key'] ?? '0',
          );
          return h.response(
            {
              'transactions': h.pages[page],
              'continuation_key': page < 2 ? '${page + 1}' : null,
            },
            headers: {
              'date': [
                'Mon, 07 Sep 2026 12:00:00 GMT',
                'Mon, 07 Sep 2026 12:03:00 GMT',
                'Mon, 07 Sep 2026 11:57:00 GMT',
              ][page],
            },
          );
        };
        expect(
          (await h.service.syncAccount(1)).warnings,
          contains('server_clock_changed'),
        );
        expect(await h.transactions(), isEmpty);
      },
    );
    for (final pages in [1, 2]) {
      test('global page budget $pages spans all rounds', () async {
        h.resetService(limits: BankSyncLimits(pages: pages, retries: 3));
        h.intercept = (r) async => r.url.path.endsWith('/balances')
            ? h.response(
                {
                  'balances': [booked(changed: '2026-09-07T12:00:01Z')],
                },
                headers: {'date': 'Mon, 07 Sep 2026 12:00:02 GMT'},
              )
            : null;
        final result = await h.service.syncAccount(1);
        expect(
          pages == 2
              ? result.completed
              : result.warnings.contains('page_limit'),
          isTrue,
        );
        expect(
          h.requests.where((r) => r.url.path.endsWith('/transactions')),
          hasLength(pages),
        );
      });
    }
  });
  group('BAL calendar', () {
    for (final instant in [
      DateTime.utc(2028, 1, 1, 0, 30),
      DateTime.utc(2028, 12, 31, 23, 30),
      DateTime.utc(2028, 2, 29, 12),
      DateTime.utc(2028, 3, 26, 1, 30),
      DateTime.utc(2028, 10, 29, 1, 30),
    ]) {
      test('controlled acquisition and civil day $instant', () async {
        h.serverTime = instant;
        h.localTime = instant;
        h.validUntil = instant.add(const Duration(days: 90));
        await h.db.update('bankConnection', {
          'validUntil': h.validUntil!.toIso8601String(),
        }, where: 'id = 1');
        final ref = instant.hour == 23
            ? DateTime.utc(instant.year, instant.month, instant.day + 1)
            : DateTime.utc(instant.year, instant.month, instant.day);
        final date = ref.toIso8601String().substring(0, 10);
        final booking = instant
            .subtract(const Duration(days: 1))
            .toIso8601String()
            .substring(0, 10);
        h.pages = [
          [bankRecord(date: booking)],
        ];
        h.intercept = (r) async => r.url.path.endsWith('/balances')
            ? h.response({
                'balances': [
                  booked(
                    reference: date,
                    changed: instant
                        .subtract(const Duration(days: 40))
                        .toIso8601String(),
                  ),
                ],
              })
            : null;
        expect((await h.service.syncAccount(1)).completed, isTrue);
        expect((await h.state())['balanceAt'], instant.toIso8601String());
        await financial();
        expect(
          h.requests.where((r) => r.url.path.endsWith('/transactions')),
          hasLength(instant.hour == 23 ? 2 : 1),
        );
      });
    }
    for (final delta in [-1, 0, 1]) {
      test('consent before at after expiry $delta', () async {
        h.validUntil = h.serverTime.add(Duration(seconds: -delta));
        await h.db.update('bankConnection', {
          'validUntil': h.validUntil!.toIso8601String(),
        }, where: 'id = 1');
        final result = await h.service.syncAccount(1);
        expect(result.completed, delta < 0);
        if (delta >= 0) {
          expect(result.warnings, contains('consent_expired'));
          expect(await h.db.query('bankSyncState'), isEmpty);
          expect(await h.transactions(), isEmpty);
        }
      });
    }
  });
}
