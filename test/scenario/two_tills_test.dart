import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/data/db/database_archive.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// Two tills, both serving, reconciling afterwards.
///
/// No cloud here: the two shops hand each other their changes directly,
/// which is the same thing the cloud will do with more steps in between.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture her;
  late PosFixture barista;
  late SyncEngine herSync;
  late SyncEngine baristaSync;

  setUp(() async {
    her = await PosFixture.open(separate: true);
    barista = await PosFixture.open(separate: true);
    await PantrySeeder(her.db, her.clock).seedIfEmpty();
    await PantrySeeder(barista.db, barista.clock).seedIfEmpty();
    herSync = SyncEngine(database: her.db, clock: her.clock);
    baristaSync = SyncEngine(database: barista.db, clock: barista.clock);

    // A second till is set up from the first one's own export, which is
    // what pairing will do: both then know every drink, ingredient and
    // recipe by the same name.
    await _pairFrom(her, barista);
  });
  tearDown(() async {
    await her.close();
    await barista.close();
  });

  /// Everything one till knows, handed to the other.
  Future<SyncApplied> push(SyncEngine from, SyncEngine to) async {
    final List<SyncChange> changes = await from.collect();
    final SyncApplied result = await to.apply(changes);
    await from.markSent(changes);
    return result;
  }

  Future<CompletedOrder> sell(
    PosFixture shop,
    String drink, {
    String size = 'Large',
    List<DraftOption> options = const <DraftOption>[],
  }) async => shop.sell(
    OrderDraft(
      items: <DraftItem>[await shop.item(drink, size, options: options)],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  Future<double> stockOf(PosFixture shop, String name) async =>
      (await shop.stock.ingredients())
          .firstWhere((Ingredient i) => i.name == name)
          .onHand!
          .inBaseUnits;

  group('both tills serving', () {
    test("each one ends up with the other's orders", () async {
      await sell(her, 'Spanish Latte');
      await sell(barista, 'Ca Phe Trung');

      await push(herSync, baristaSync);
      await push(baristaSync, herSync);

      for (final PosFixture shop in <PosFixture>[her, barista]) {
        final List<OrderRecord> orders = await shop.sales.orders();
        expect(
          orders.map((OrderRecord o) => o.lines.single.productName).toSet(),
          <String>{'Spanish Latte', 'Ca Phe Trung'},
        );
      }
    });

    test('the lines, the options and the payment come with it', () async {
      await sell(
        barista,
        'Spanish Latte',
        options: <DraftOption>[
          await barista.draftOption('extras', 'Sea Salt Cold Foam'),
        ],
      );

      await push(baristaSync, herSync);

      final OrderRecord order = (await her.sales.orders()).single;
      expect(order.lines.single.optionNames, contains('Sea Salt Cold Foam'));
      expect(order.paymentMethod?.code, 'cash');
      expect(order.total, Money.of(159));
    });

    test('the day adds up to both tills together', () async {
      await sell(her, 'Spanish Latte');
      await sell(barista, 'Spanish Latte');
      await sell(barista, 'Iced Black');

      await push(herSync, baristaSync);
      await push(baristaSync, herSync);

      final SalesSummary day = await her.reports.forDay(her.reports.today);
      expect(day.orderCount, 3);
      expect(day.revenue, Money.of(139 + 139 + 129));
    });

    test('two tills never hand out the same order number', () async {
      final CompletedOrder hers = await sell(her, 'Spanish Latte');
      final CompletedOrder theirs = await sell(barista, 'Spanish Latte');

      expect(hers.orderNo, 'KUBO-1001');
      expect(theirs.orderNo, 'KUBO-5001');
    });
  });

  group('stock, when both tills took from the same shelf', () {
    test('what each one used comes off', () async {
      final double before = await stockOf(her, 'Sang Tao 1');

      await sell(her, 'Spanish Latte'); // 22 g
      await sell(barista, 'Spanish Latte'); // 22 g

      await push(herSync, baristaSync);
      await push(baristaSync, herSync);

      expect(await stockOf(her, 'Sang Tao 1'), before - 44);
      expect(await stockOf(barista, 'Sang Tao 1'), before - 44);
    });

    test('overselling shows as overselling, not as zero', () async {
      // One cup left on the shelf, counted on her till and told to the
      // other, so both start from the same shelf.
      final Ingredient cup = (await her.stock.ingredients()).firstWhere(
        (Ingredient i) => i.name == 'Large cup 16oz',
      );
      await her.stock.applyStockCount(
        counted: <int, Quantity>{cup.id: Quantity.fromBase(1, BaseUnit.piece)},
        note: 'Down to the last cup',
      );
      await push(herSync, baristaSync);
      expect(await stockOf(barista, 'Large cup 16oz'), 1);

      // And both tills sell it.
      await sell(her, 'Spanish Latte');
      await sell(barista, 'Spanish Latte');
      await push(herSync, baristaSync);
      await push(baristaSync, herSync);

      // Both agree, and both say the shelf is one short — which is the
      // truth, and the thing she has to know.
      expect(await stockOf(her, 'Large cup 16oz'), -1);
      expect(await stockOf(barista, 'Large cup 16oz'), -1);
    });
  });

  group('the menu, which only she edits', () {
    test('a price change reaches the other till', () async {
      final List<Map<String, Object?>> row = await her.db.db.rawQuery(
        'SELECT ps.id FROM product_sizes ps '
        'JOIN products p ON p.id = ps.product_id '
        'JOIN sizes s ON s.id = ps.size_id '
        "WHERE p.name = 'Spanish Latte' AND s.name = 'Large'",
      );
      await her.db.db.update(
        'product_sizes',
        <String, Object?>{
          'price_centavos': 14900,
          'updated_at': '2026-03-16T00:00:00.000Z',
        },
        where: 'id = ?',
        whereArgs: <Object?>[row.single['id']],
      );

      await push(herSync, baristaSync);

      expect(
        (await barista.size('Spanish Latte', 'Large')).price,
        Money.of(149),
      );
    });

    test('an older edit does not undo a newer one', () async {
      Future<void> setPrice(PosFixture shop, int price, String at) async {
        final List<Map<String, Object?>> row = await shop.db.db.rawQuery(
          'SELECT ps.id FROM product_sizes ps '
          'JOIN products p ON p.id = ps.product_id '
          'JOIN sizes s ON s.id = ps.size_id '
          "WHERE p.name = 'Spanish Latte' AND s.name = 'Large'",
        );
        await shop.db.db.update(
          'product_sizes',
          <String, Object?>{'price_centavos': price, 'updated_at': at},
          where: 'id = ?',
          whereArgs: <Object?>[row.single['id']],
        );
      }

      await setPrice(barista, 15900, '2026-03-18T00:00:00.000Z');
      await setPrice(her, 14900, '2026-03-16T00:00:00.000Z');

      await push(herSync, baristaSync);

      expect(
        (await barista.size('Spanish Latte', 'Large')).price,
        Money.of(159),
        reason: 'the newer edit stands',
      );
    });
  });

  group('the awkward cases', () {
    test('hearing the same thing twice changes nothing', () async {
      await sell(barista, 'Spanish Latte');
      final List<SyncChange> changes = await baristaSync.collect();

      final SyncApplied first = await herSync.apply(changes);
      final SyncApplied again = await herSync.apply(changes);

      expect(first.applied, greaterThan(0));
      expect(again.applied, 0);
      expect(again.alreadyKnown, greaterThan(0));
      expect(await her.sales.orders(), hasLength(1));
    });

    test('a line that arrives before its order waits for it', () async {
      await sell(barista, 'Spanish Latte');
      final List<SyncChange> changes = await baristaSync.collect();
      final List<SyncChange> backwards = changes.reversed.toList();

      final SyncApplied result = await herSync.apply(backwards);

      expect(result.waitingForParent, 0, reason: 'a second pass catches up');
      expect((await her.sales.orders()).single.lines, hasLength(1));
    });

    test(
      'an order with no sign of its drink is held, not half-written',
      () async {
        await sell(barista, 'Spanish Latte');
        final List<SyncChange> changes = await baristaSync.collect();
        // The line alone, with nothing it points at.
        final SyncChange orphan = changes.firstWhere(
          (SyncChange c) => c.table == 'order_items',
        );

        final SyncApplied result = await herSync.apply(<SyncChange>[orphan]);

        expect(result.applied, 0);
        expect(result.waitingForParent, 1);
        expect(await her.countOf('order_items'), 0);
      },
    );

    test('what came in is not sent back out again', () async {
      final int before = await herSync.pendingCount();

      await sell(barista, 'Spanish Latte');
      await push(baristaSync, herSync);

      expect(
        await herSync.pendingCount(),
        before,
        reason: 'the barista\'s order is his news, not hers to repeat',
      );
    });

    test('a till with nothing new to say says nothing', () async {
      // Her till still has the shop itself to tell — the menu, the
      // recipes — because the barista's was set up from an export rather
      // than from the wire. Once that has gone, silence.
      await push(herSync, baristaSync);

      expect(await herSync.collect(), isEmpty);
      expect(await herSync.pendingCount(), 0);
    });
  });
}

/// Sets the second till up from the first one's export.
///
/// Not a shortcut for the test: it is the only sane way to add a till. Two
/// shops seeded separately have two of everything under different names,
/// and no amount of merging afterwards can tell that one shop's Spanish
/// Latte is the other's.
Future<void> _pairFrom(PosFixture first, PosFixture second) async {
  final String export = await DatabaseArchive(
    first.db.db,
    first.clock,
  ).export();
  await DatabaseArchive(second.db.db, second.clock).restore(export);
  // Everything that arrived came from her till, not from this one.
  await second.db.db.delete('sync_outbox');
  await second.db.db.update('sync_devices', <String, Object?>{
    'number_base': 5001,
  }, where: 'is_this_one = 1');
  second.settings = second.settings.copyWith(orderNumberStart: 5001);
}
