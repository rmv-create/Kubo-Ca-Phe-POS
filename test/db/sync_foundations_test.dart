import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/migrations/m012_sync_foundations.dart';
import 'package:kubo_pos/data/db/sync/synced_tables.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';

/// What two tills need before they can be told to agree: a name for every
/// row that both devices mean the same thing by, and a record of every
/// change as it happens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async => shop = await PosFixture.open());
  tearDown(() async => shop.close());

  Future<List<Map<String, Object?>>> outbox() =>
      shop.db.db.query('sync_outbox', orderBy: 'id');

  group('a name every device agrees on', () {
    test('every synced table carries one', () async {
      for (final String table in syncedTableNames) {
        final List<Map<String, Object?>> columns = await shop.db.db.rawQuery(
          'PRAGMA table_info($table)',
        );
        expect(
          columns.map((Map<String, Object?> c) => c['name']),
          contains('uid'),
          reason: table,
        );
      }
    });

    test('the rows that were already there were given one', () async {
      final List<Map<String, Object?>> products = await shop.db.db.query(
        'products',
      );

      expect(products, isNotEmpty);
      for (final Map<String, Object?> row in products) {
        expect((row['uid']! as String).length, 32, reason: '${row['name']}');
      }
      expect(
        products.map((Map<String, Object?> r) => r['uid']).toSet(),
        hasLength(products.length),
        reason: 'two drinks must never share a name',
      );
    });

    test('the same name cannot be used twice', () async {
      final String taken =
          (await shop.db.db.query('products', limit: 1)).single['uid']!
              as String;

      await expectLater(
        shop.db.db.rawUpdate(
          'UPDATE products SET uid = ? WHERE id = '
          '(SELECT MAX(id) FROM products)',
          <Object?>[taken],
        ),
        throwsA(anything),
      );
    });

    test('stock on hand is left out on purpose', () {
      // It is a running total of the movement ledger. Syncing the total as
      // well as the movements is how two tills end up agreeing on a number
      // that is wrong.
      expect(syncedTableNames, isNot(contains('inventory')));
      expect(syncedTableNames, contains('inventory_movements'));
    });
  });

  group('the record of what changed', () {
    test('a sale queues everything it wrote', () async {
      await shop.db.db.delete('sync_outbox');

      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      final Set<String?> tables = <String?>{
        for (final Map<String, Object?> row in await outbox())
          row['table_name'] as String?,
      };
      expect(
        tables,
        containsAll(<String>['orders', 'order_items', 'payments']),
      );
      expect(
        tables,
        isNot(contains('inventory')),
        reason: 'the running total is rebuilt, never sent',
      );
    });

    test('an edit is queued as well as a new row', () async {
      await shop.db.db.delete('sync_outbox');

      await shop.db.db.update('products', <String, Object?>{
        'name': 'Renamed',
      }, where: 'id = (SELECT MIN(id) FROM products)');

      final Map<String, Object?> change = (await outbox()).single;
      expect(change['table_name'], 'products');
      expect(change['op'], 'upsert');
      expect(change['row_uid'], isNotNull, reason: 'the row still exists');
    });

    test('a delete is queued with the name, not the row', () async {
      final Map<String, Object?> supplier = <String, Object?>{
        'name': 'Passing trade',
        'created_at': '2026-03-15T00:00:00Z',
        'updated_at': '2026-03-15T00:00:00Z',
      };
      final int id = await shop.db.db.insert('suppliers', supplier);
      final String uid =
          (await shop.db.db.query(
                'suppliers',
                where: 'id = ?',
                whereArgs: <Object?>[id],
              )).single['uid']!
              as String;
      await shop.db.db.delete('sync_outbox');

      await shop.db.db.delete(
        'suppliers',
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );

      final Map<String, Object?> change = (await outbox()).single;
      expect(change['op'], 'delete');
      expect(
        change['row_uid'],
        uid,
        reason: 'the other till knows the row by its name, not by our id',
      );
    });

    test('nothing is marked as sent until it has been', () async {
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Iced Black', 'Small')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      expect(
        (await outbox()).every(
          (Map<String, Object?> row) => row['sent_at'] == null,
        ),
        isTrue,
      );
    });
  });

  group('order numbers that cannot collide', () {
    test('this till knows itself, and where its numbers start', () async {
      final Map<String, Object?> device = (await shop.db.db.query(
        'sync_devices',
        where: 'is_this_one = 1',
      )).single;

      expect((device['device_id']! as String).length, 16);
      expect(device['number_base'], 1001);
    });

    test('a block is wide enough that a till never runs out', () {
      // Her busiest day, as she described it, is 100 to 200 drinks.
      expect(
        M012SyncFoundations.orderNumberBlockSize / 200,
        greaterThan(365 / 30),
        reason: 'a block should last years, not weeks',
      );
    });
  });
}
