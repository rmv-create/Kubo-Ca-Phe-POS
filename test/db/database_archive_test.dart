import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/db/database_archive.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// The backup that works in a browser, where there is no disk to copy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late DatabaseArchive archive;

  setUp(() async {
    shop = await PosFixture.open();
    archive = DatabaseArchive(shop.db.db, shop.clock);
  });
  tearDown(() async => shop.close());

  Future<CompletedOrder> sellOne() async => shop.sell(
    OrderDraft(
      items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  group('what comes out', () {
    test('says what it is, and when it was taken', () async {
      final String sql = await archive.export();

      expect(sql, startsWith('-- Kubo Cà Phê backup'));
      final ArchiveHeader header = DatabaseArchive.describe(sql)!;
      expect(header.takenAt!.toUtc(), shop.clock.now().toUtc());
      expect(header.schemaVersion, greaterThan(0));
      expect(header.rowCount, greaterThan(0));
    });

    test('carries the menu and the sales', () async {
      await sellOne();
      final String sql = await archive.export();

      expect(sql, contains('Spanish Latte'));
      expect(sql, contains('INSERT INTO "orders"'));
      expect(sql, contains('INSERT INTO "order_items"'));
    });

    test('an apostrophe in a name does not break the file', () async {
      await shop.customers.create(name: "Tita O'Brien");

      final String sql = await archive.export();

      expect(sql, contains("Tita O''Brien"));
      // And it goes back in as it came out.
      await archive.restore(sql);
      final List<Customer> all = await shop.customers.search('Tita');
      expect(all.single.name, "Tita O'Brien");
    });
  });

  group('putting it back', () {
    test('brings back a sale that was deleted after the export', () async {
      final CompletedOrder sold = await sellOne();
      final String sql = await archive.export();
      await shop.db.db.delete('order_items');
      await shop.db.db.delete('orders');
      expect(await shop.sales.orderById(sold.id), isNull);

      await archive.restore(sql);

      final OrderRecord? back = await shop.sales.orderById(sold.id);
      expect(back, isNotNull);
      expect(back!.total, Money.of(139));
      expect(back.lines.single.productName, 'Spanish Latte');
    });

    test('replaces what is there rather than doubling it', () async {
      await sellOne();
      final String sql = await archive.export();

      await archive.restore(sql);
      await archive.restore(sql);

      expect(await shop.countOf('orders'), 1);
      expect(await shop.countOf('products'), 9);
    });

    test('a sale made after the export is gone, as she would expect', () async {
      final String sql = await archive.export();
      await sellOne();

      await archive.restore(sql);

      expect(await shop.countOf('orders'), 0);
    });

    test('the records still hang together afterwards', () async {
      await sellOne();
      final String sql = await archive.export();

      await archive.restore(sql);

      final List<Map<String, Object?>> broken = await shop.db.db.rawQuery(
        'PRAGMA foreign_key_check',
      );
      expect(broken, isEmpty);
    });

    test('the next order number carries on from the backup', () async {
      await sellOne();
      final String sql = await archive.export();
      await archive.restore(sql);

      final CompletedOrder next = await sellOne();
      expect(next.orderNo, 'KUBO-1002', reason: 'not back to 1001');
    });
  });

  group('refusing a file it should not take', () {
    test('something that is not a backup at all', () async {
      await expectLater(
        archive.restore('SELECT * FROM orders;'),
        throwsA(isA<BackupException>()),
      );
    });

    test('a backup from a newer version of the app', () async {
      final String sql = (await archive.export()).replaceFirst(
        RegExp(r'-- schema: \d+'),
        '-- schema: 999',
      );

      await expectLater(archive.restore(sql), throwsA(isA<BackupException>()));
    });

    test('an empty one leaves the shop alone', () async {
      await sellOne();

      await expectLater(
        archive.restore('-- Kubo Cà Phê backup\n-- schema: 1\n'),
        throwsA(isA<BackupException>()),
      );
      expect(await shop.countOf('orders'), 1);
    });

    test('describe says nothing about a file it does not know', () {
      expect(DatabaseArchive.describe('hello'), isNull);
    });
  });
}
