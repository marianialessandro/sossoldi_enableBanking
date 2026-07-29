import 'package:flutter_test/flutter_test.dart';
import 'package:sossoldi/model/base_entity.dart';
import 'package:sossoldi/model/bank_connection.dart';
import 'package:sossoldi/services/database/repositories/bank_connection_repository.dart';
import 'package:sossoldi/services/database/sossoldi_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;

void main() {
  test('BankConnectionStatus code roundtrips through fromJson', () {
    for (final status in BankConnectionStatus.values) {
      expect(BankConnectionStatus.fromJson(status.code), status);
    }
    expect(BankConnectionStatus.active.code, 'ACTIVE');
    expect(BankConnectionStatus.expired.code, 'EXPIRED');
    expect(BankConnectionStatus.revoked.code, 'REVOKED');
  });

  test('Test Copy BankConnection', () {
    final c = BankConnection(
      id: 1,
      aspspName: 'Test Bank',
      aspspCountry: 'IT',
      sessionId: 'sess-1',
      validUntil: DateTime.utc(2026, 12, 31),
      status: BankConnectionStatus.active,
      psuType: 'personal',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

    final copy = c.copy(status: BankConnectionStatus.expired);

    expect(copy.id, c.id);
    expect(copy.aspspName, c.aspspName);
    expect(copy.aspspCountry, c.aspspCountry);
    expect(copy.sessionId, c.sessionId);
    expect(copy.validUntil, c.validUntil);
    expect(copy.status, BankConnectionStatus.expired);
    expect(copy.psuType, c.psuType);
    expect(copy.createdAt, c.createdAt);
    expect(copy.updatedAt, c.updatedAt);
  });

  test('Test fromJson BankConnection', () {
    final json = {
      BaseEntityFields.id: 5,
      BankConnectionFields.aspspName: 'Test Bank',
      BankConnectionFields.aspspCountry: 'IT',
      BankConnectionFields.sessionId: 'sess-1',
      BankConnectionFields.validUntil: '2026-12-31T00:00:00.000Z',
      BankConnectionFields.status: 'EXPIRED',
      BankConnectionFields.psuType: 'personal',
      BaseEntityFields.createdAt: '2026-01-01T00:00:00.000Z',
      BaseEntityFields.updatedAt: '2026-01-02T00:00:00.000Z',
    };

    final c = BankConnection.fromJson(json);

    expect(c.id, 5);
    expect(c.aspspName, 'Test Bank');
    expect(c.aspspCountry, 'IT');
    expect(c.sessionId, 'sess-1');
    expect(c.validUntil, DateTime.parse('2026-12-31T00:00:00.000Z'));
    expect(c.status, BankConnectionStatus.expired);
    expect(c.psuType, 'personal');
    expect(c.createdAt, DateTime.parse('2026-01-01T00:00:00.000Z'));
    expect(c.updatedAt, DateTime.parse('2026-01-02T00:00:00.000Z'));
  });

  test('Test toJson BankConnection', () {
    final c = BankConnection(
      aspspName: 'Test Bank',
      aspspCountry: 'IT',
      sessionId: 'sess-1',
      validUntil: DateTime.utc(2026, 12, 31),
      status: BankConnectionStatus.active,
    );

    final json = c.toJson();

    expect(json[BankConnectionFields.aspspName], 'Test Bank');
    expect(json[BankConnectionFields.aspspCountry], 'IT');
    expect(json[BankConnectionFields.sessionId], 'sess-1');
    expect(json[BankConnectionFields.validUntil], '2026-12-31T00:00:00.000Z');
    expect(json[BankConnectionFields.status], 'ACTIVE');
    expect(json[BankConnectionFields.psuType], isNull);
  });

  group('Bank Connection Methods', () {
    late SossoldiDatabase sossoldiDatabase;

    setUpAll(() async {
      sqflite_ffi.sqfliteFfiInit();
      sqflite_ffi.databaseFactory = sqflite_ffi.databaseFactoryFfi;

      sossoldiDatabase = SossoldiDatabase(dbName: 'test.db');
      await sossoldiDatabase.database;
      await sossoldiDatabase.resetDatabase();
    });

    tearDown(() async => sossoldiDatabase.clearDatabase());

    tearDownAll(() {
      sossoldiDatabase.close();
    });

    test('insert / selectById / selectAll / selectActive / markStatus / '
        'updateItem / deleteById', () async {
      final repo = BankConnectionRepository(database: sossoldiDatabase);

      final inserted = await repo.insert(
        BankConnection(
          aspspName: 'Test Bank',
          aspspCountry: 'IT',
          sessionId: 'sess-1',
          validUntil: DateTime.utc(2026, 12, 31),
          status: BankConnectionStatus.active,
          psuType: 'personal',
        ),
      );
      expect(inserted.id, isNotNull);

      final fetched = await repo.selectById(inserted.id!);
      expect(fetched.aspspName, 'Test Bank');
      expect(fetched.status, BankConnectionStatus.active);

      final active = await repo.selectActive();
      expect(active.map((c) => c.id), [inserted.id]);

      await repo.markStatus(inserted.id!, BankConnectionStatus.expired);
      final afterMarkStatus = await repo.selectById(inserted.id!);
      expect(afterMarkStatus.status, BankConnectionStatus.expired);
      expect(await repo.selectActive(), isEmpty);

      final updatedRows = await repo.updateItem(
        afterMarkStatus.copy(aspspName: 'Renamed Bank'),
      );
      expect(updatedRows, 1);
      expect((await repo.selectById(inserted.id!)).aspspName, 'Renamed Bank');

      expect(await repo.selectAll(), hasLength(1));

      await repo.deleteById(inserted.id!);
      expect(await repo.selectAll(), isEmpty);
      expect(() => repo.selectById(inserted.id!), throwsException);
    });
  });
}
