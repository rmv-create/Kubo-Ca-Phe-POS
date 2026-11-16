import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// Rows arriving before, or after, the rows they are bound to.
///
/// The log is a stream, not a tree. An order line can reach the other phone
/// ahead of its order; an order's deletion can reach it ahead of the
/// deletion of the void attached to it. Both are ordinary, and the engine
/// is built to come back for whatever it cannot place yet.
///
/// It did not. A foreign key failure was thrown rather than deferred, so
/// one awkwardly ordered row stopped the whole sync and the phone showed
/// "FOREIGN KEY constraint failed (code 1811)" with the shop not syncing
/// at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture her;
  late PosFixture other;
  late SyncEngine herSync;
  late SyncEngine otherSync;

  setUp(() async {
    her = await PosFixture.open(separate: true);
    // A phone just let in, holding nothing: when everything arrives at
    // once, plenty of it arrives before what it points at.
    other = await PosFixture.openBlank(separate: true);
    await PantrySeeder(her.db, her.clock).seedIfEmpty();
    herSync = SyncEngine(database: her.db, clock: her.clock);
    otherSync = SyncEngine(database: other.db, clock: other.clock);
  });

  tearDown(() async {
    await her.close();
    await other.close();
  });

  Future<CompletedOrder> sell() async => her.sell(
    OrderDraft(
      items: <DraftItem>[await her.item('Iced Black', 'Large')],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  Future<int> countOn(PosFixture shop, String table) async =>
      (await shop.db.db.rawQuery('SELECT COUNT(*) c FROM $table')).first['c']!
          as int;

  group('a deleted practice order', () {
    test('does not stop the other phone syncing', () async {
      // Exactly what she did: rang up practice orders, then deleted them.
      final CompletedOrder keep = await sell();
      final CompletedOrder bin = await sell();
      await her.sales.deleteOrder(orderId: bin.id, reason: 'Practice');

      final List<SyncChange> all = await herSync.collect();
      final SyncApplied result = await otherSync.apply(all);

      expect(result.waitingForParent, 0);
      expect((await other.sales.orders()).single.orderNo, keep.orderNo);
    });

    test('survives the deletions arriving the wrong way round', () async {
      // The order's own deletion put first, ahead of the void's — which
      // the schema refuses, because a void may not outlive its order.
      await sell();
      final CompletedOrder bin = await sell();
      await her.sales.deleteOrder(orderId: bin.id, reason: 'Practice');

      final List<SyncChange> all = await herSync.collect();
      final List<SyncChange> deletes = <SyncChange>[
        for (final SyncChange c in all)
          if (c.op == SyncOp.delete) c,
      ];
      expect(deletes, isNotEmpty, reason: 'the shape under test');

      final SyncApplied result = await otherSync.apply(<SyncChange>[
        ...deletes,
        for (final SyncChange c in all)
          if (c.op != SyncOp.delete) c,
      ]);

      expect(result.waitingForParent, 0);
      expect((await other.sales.orders()).length, 1);
    });
  });

  group('a shop arriving all at once', () {
    test('lands whole, in whatever order it comes', () async {
      await sell();
      final List<SyncChange> all = await herSync.collect();

      final SyncApplied result = await otherSync.apply(all);

      expect(result.waitingForParent, 0);
      // The thing that was actually broken: an order used to arrive with
      // no drinks in it, because its lines pointed at her copy of the
      // drink and this phone only had its own.
      expect(await countOn(other, 'order_items'), 1);
      expect(await countOn(other, 'recipe_items'), 180);
      expect(await countOn(other, 'recipes'), 18);
    });

    test('lands whole even when dealt exactly backwards', () async {
      await sell();
      final List<SyncChange> all = await herSync.collect();

      final SyncApplied result = await otherSync.apply(all.reversed.toList());

      expect(result.waitingForParent, 0);
      expect(await countOn(other, 'order_items'), 1);
      expect(await countOn(other, 'recipe_items'), 180);
    });

    test('and the sale reads the same on both phones', () async {
      final CompletedOrder sold = await sell();
      await otherSync.apply((await herSync.collect()).reversed.toList());

      final OrderRecord there = (await other.sales.orders()).single;
      expect(there.orderNo, sold.orderNo);
      expect(there.total, sold.total);
      expect(there.lines.single.productName, 'Iced Black');
    });
  });

  group('two tills that each made their own menu', () {
    test(
      'agree which drink is which, rather than stranding the order',
      () async {
        // Both seeded separately, so each has its own "Iced Black" under its
        // own name. Her order's lines point at hers.
        final PosFixture twin = await PosFixture.open(separate: true);
        await PantrySeeder(twin.db, twin.clock).seedIfEmpty();
        final SyncEngine twinSync = SyncEngine(
          database: twin.db,
          clock: twin.clock,
        );
        addTearDown(twin.close);

        await sell();
        final SyncApplied result = await twinSync.apply(
          await herSync.collect(),
        );

        expect(result.waitingForParent, 0);
        expect(await countOn(twin, 'order_items'), 1);
        // One Iced Black, not two: the same thing under one name now.
        final List<Map<String, Object?>> black = await twin.db.db.query(
          'products',
          where: 'name = ?',
          whereArgs: <Object?>['Iced Black'],
        );
        expect(black.length, 1);
      },
    );
  });
}
