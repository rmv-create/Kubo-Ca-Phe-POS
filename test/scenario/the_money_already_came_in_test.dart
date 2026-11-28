import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/migrations/m024_money_that_already_arrived.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';

/// What happens to a sale *after* it is rung up.
///
/// A sale is written once, so the engine treated every later telling of an
/// order as a repeat and dropped it. Most of the time that is exactly
/// right. But some things about a sale genuinely happen afterwards — the
/// money arrives on an order that went out on credit, the order is voided
/// — and those were going over the side with the repeats.
///
/// Her words, the morning it landed: "112 orders still owed, the ones I
/// already received payment for are owed again."
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
  });
  tearDown(() async {
    await her.close();
    await barista.close();
  });

  Future<SyncApplied> push(SyncEngine from, SyncEngine to) async {
    final List<SyncChange> changes = await from.collect();
    final SyncApplied result = await to.apply(changes);
    await from.markSent(changes);
    return result;
  }

  Future<CompletedOrder> sellOnCredit(PosFixture shop) async => shop.sell(
    OrderDraft(
      items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
      unpaid: true,
    ),
  );

  Future<String?> stateOn(PosFixture shop, String orderNo) async {
    final List<Map<String, Object?>> rows = await shop.db.db.query(
      'orders',
      columns: <String>['payment_state', 'status'],
      where: 'order_no = ?',
      whereArgs: <Object?>[orderNo],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : '${rows.first['payment_state']}/${rows.first['status']}';
  }

  test('an order paid for after it was rung up is not still owed', () async {
    final CompletedOrder sale = await sellOnCredit(barista);
    await push(baristaSync, herSync);
    expect(await stateOn(her, sale.orderNo), 'unpaid/completed');

    // The customer comes back and settles up at his till.
    await barista.sales.recordPayment(
      orderId: sale.id,
      method: PaymentMethod.cash,
    );
    await push(baristaSync, herSync);

    expect(
      await stateOn(her, sale.orderNo),
      'paid/completed',
      reason: 'she had been paid, and her phone still asked for the money',
    );
  });

  test('and it is not talked back into being owed afterwards', () async {
    final CompletedOrder sale = await sellOnCredit(barista);
    await push(baristaSync, herSync);
    await barista.sales.recordPayment(
      orderId: sale.id,
      method: PaymentMethod.cash,
    );
    await push(baristaSync, herSync);

    // The same order arrives again from a phone that has not heard yet —
    // an older copy, out of a queue that had been standing for two days.
    final List<SyncChange> stale = await baristaSync.collect(limit: 500);
    await herSync.apply(stale);
    await herSync.apply(stale);

    expect(await stateOn(her, sale.orderNo), 'paid/completed');
  });

  test('a void crosses as well, and is not undone', () async {
    final CompletedOrder sale = await sellOnCredit(barista);
    await push(baristaSync, herSync);

    await barista.sales.voidOrder(orderId: sale.id, reason: 'Wrong drink');
    await push(baristaSync, herSync);

    expect(await stateOn(her, sale.orderNo), 'unpaid/voided');
  });

  test('neither phone talks the other backwards', () async {
    final CompletedOrder sale = await sellOnCredit(her);
    await push(herSync, baristaSync);

    // She takes the money on her phone. He has not heard yet, and his copy
    // still says owed — but his copy must not undo hers.
    await her.sales.recordPayment(orderId: sale.id, method: PaymentMethod.cash);
    await push(baristaSync, herSync);
    await push(herSync, baristaSync);

    expect(await stateOn(her, sale.orderNo), 'paid/completed');
    expect(await stateOn(barista, sale.orderNo), 'paid/completed');
  });

  test('a payment that crosses alone still settles the order', () async {
    // The one that cost a week: the payment record always crosses, because
    // it is an event. The word "paid" on the order is an update, and an
    // update can be dropped. So the order is read back off the records
    // instead of waiting to be told.
    final CompletedOrder sale = await sellOnCredit(barista);
    await push(baristaSync, herSync);
    await barista.sales.recordPayment(
      orderId: sale.id,
      method: PaymentMethod.cash,
    );

    // Only the payment itself goes across; the order's own change is lost
    // on the way, as it was for a hundred and twelve of hers.
    final List<SyncChange> all = await baristaSync.collect();
    await herSync.apply(<SyncChange>[
      for (final SyncChange c in all)
        if (c.table != 'orders') c,
    ]);

    expect(
      await stateOn(her, sale.orderNo),
      'paid/completed',
      reason: 'her phone was holding the payment the whole time',
    );
  });

  test('a void that crosses alone settles the order too', () async {
    final CompletedOrder sale = await sellOnCredit(barista);
    await push(baristaSync, herSync);
    await barista.sales.voidOrder(orderId: sale.id, reason: 'Wrong drink');

    final List<SyncChange> all = await baristaSync.collect();
    await herSync.apply(<SyncChange>[
      for (final SyncChange c in all)
        if (c.table != 'orders') c,
    ]);

    expect(await stateOn(her, sale.orderNo), 'unpaid/voided');
  });

  test('and nothing is invented for an order with no payment', () async {
    final CompletedOrder sale = await sellOnCredit(barista);
    await push(baristaSync, herSync);
    await herSync.settleWhatFollows();

    expect(
      await stateOn(her, sale.orderNo),
      'unpaid/completed',
      reason: 'an order nobody has paid for is still owed',
    );
  });

  test('the same money is not counted twice in the takings', () async {
    // What she did while her phone kept asking for money she already had:
    // received it again. The order is paid either way; the takings she
    // reconciles against the tin were counting it twice.
    final CompletedOrder sale = await sellOnCredit(her);
    await her.sales.recordPayment(orderId: sale.id, method: PaymentMethod.cash);
    // A second recording of the same money, as the broken state allowed.
    await her.db.db.insert('payments', <String, Object?>{
      'order_id': sale.id,
      'method': 'cash',
      'method_name_snapshot': 'Cash',
      'amount_centavos': 13900,
      'status': 'confirmed',
      'created_at': her.clock.now().toUtc().toIso8601String(),
      'confirmed_at': her.clock.now().toUtc().toIso8601String(),
    });

    await const M024MoneyThatAlreadyArrived().up(her.db.db);

    final List<Map<String, Object?>> standing = await her.db.db.rawQuery(
      'SELECT status, COUNT(*) AS n FROM payments WHERE order_id = ? '
      'GROUP BY status ORDER BY status',
      <Object?>[sale.id],
    );
    expect(standing, <Map<String, Object?>>[
      <String, Object?>{'status': 'confirmed', 'n': 1},
      <String, Object?>{'status': 'pending', 'n': 1},
    ], reason: 'one counted, the other kept but stood down — never deleted');
  });
}
