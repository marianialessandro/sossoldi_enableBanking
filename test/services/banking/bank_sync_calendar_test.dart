import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../support/bank_sync_harness.dart';

void main() {
  sqfliteFfiInit();
  tzdata.initializeTimeZones();

  for (final zone in ['UTC', 'Europe/Rome']) {
    for (final (month, day, lastDay) in [
      (1, 1, 31),
      (12, 31, 31),
      (2, 29, 29),
      (3, 28, 31),
      (10, 31, 31),
    ]) {
      test('CAL civil month and sync $zone 2032-$month-$day', () async {
        final location = tz.getLocation(zone);
        final from = tz.TZDateTime(location, 2032, month, 1);
        final until = tz.TZDateTime(location, 2032, month + 1, 1);
        final to = until.subtract(const Duration(microseconds: 1));
        final instant = tz.TZDateTime(location, 2032, month, day, 12).toUtc();
        final booking =
            '2032-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
        final h = BankSyncHarness(databaseFactoryFfi)
          ..serverTime = instant
          ..localTime = instant
          ..validUntil = until.toUtc().add(const Duration(days: 1))
          ..pages = [
            [bankRecord(date: booking)],
          ];
        await h.open();
        try {
          await h.api.getTransactions(
            'synthetic-uid-1',
            dateFrom: from,
            dateTo: to,
          );
          final query = h.requests.single.url.queryParameters;
          final prefix = '2032-${month.toString().padLeft(2, '0')}-';
          expect(query['date_from'], '${prefix}01');
          expect(query['date_to'], '$prefix$lastDay');
          expect(from.day, 1);
          expect(to.day, lastDay);
          expect(until.year, month == 12 ? 2033 : 2032);
          expect(until.month, month == 12 ? 1 : month + 1);
          if (zone == 'Europe/Rome' && [3, 10].contains(month)) {
            expect(from.timeZoneOffset, isNot(to.timeZoneOffset));
          }
          h.requests.clear();
          expect((await h.service.syncAccount(1)).completed, isTrue);
          final state = await h.state();
          final rows = await h.transactions();
          expect(rows.single['date'], '${booking}T00:00:00.000Z');
          expect(state['balanceAt'], instant.toIso8601String());
          expect(state['balanceMinor'], '23275');
          expect(state['openingMinor'], '30589');
          expect(await h.total(), closeTo(232.75, .000001));
          expect((await h.service.syncAccount(1)).completed, isTrue);
          expect(await h.transactions(), rows);
        } finally {
          await h.close();
        }
      });
    }
  }
}
