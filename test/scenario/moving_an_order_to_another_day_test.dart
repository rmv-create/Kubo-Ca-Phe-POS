import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// Putting an order on the day it was really taken.
///
/// The one she asked for by name: an order entered the morning after, or
/// rung up at six for a sale that was really last night's, should be able to
/// move without being deleted and typed in again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
  });
  tearDown(() async => shop.close());

  Future<CompletedOrder> aSale() async => shop.sell(
    OrderDraft(
      items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  test('it leaves the day it was on and joins the one she chose', () async {
    final CompletedOrder sold = await aSale();
    expect(sold.businessDate, '2026-03-15');

    await shop.sales.changeOrderDate(
      orderId: sold.id,
      day: DateTime(2026, 3, 14),
    );

    final SalesSummary wasOn = await shop.reports.forDay('2026-03-15');
    final SalesSummary nowOn = await shop.reports.forDay('2026-03-14');
    expect(wasOn.orderCount, 0);
    expect(nowOn.orderCount, 1);
    expect(nowOn.revenue, sold.total);
  });

  test('it keeps its number, its drinks and its money', () async {
    final CompletedOrder sold = await aSale();
    await shop.sales.changeOrderDate(
      orderId: sold.id,
      day: DateTime(2026, 3, 14),
    );

    final OrderRecord? order = await shop.sales.orderById(sold.id);
    expect(order!.orderNo, sold.orderNo);
    expect(order.businessDate, '2026-03-14');
    expect(order.total, sold.total);
    expect(order.lines.single.productName, 'Spanish Latte');
    expect(order.paymentMethod, PaymentMethod.cash);
  });

  test('it is served at the same time of day, on the new day', () async {
    final CompletedOrder sold = await aSale();
    await shop.sales.changeOrderDate(
      orderId: sold.id,
      day: DateTime(2026, 3, 14),
    );

    final OrderRecord? order = await shop.sales.orderById(sold.id);
    expect(order!.createdAt.hour, sold.createdAt.hour);
    expect(order.createdAt.minute, sold.createdAt.minute);
    expect(order.createdAt.day, 14);
  });

  test('what it cost to make moves with it', () async {
    final CompletedOrder sold = await aSale();
    await shop.sales.changeOrderDate(
      orderId: sold.id,
      day: DateTime(2026, 3, 14),
    );

    final List<Map<String, Object?>> days = await shop.db.db.rawQuery(
      'SELECT DISTINCT business_date AS d FROM inventory_movements '
      'WHERE order_id = ?',
      <Object?>[sold.id],
    );
    expect(days.map((Map<String, Object?> r) => r['d']), <String>[
      '2026-03-14',
    ]);
  });

  test('a void moves with it too', () async {
    final CompletedOrder sold = await aSale();
    await shop.sales.voidOrder(orderId: sold.id, reason: 'Wrong order');
    await shop.sales.changeOrderDate(
      orderId: sold.id,
      day: DateTime(2026, 3, 14),
    );

    final List<Map<String, Object?>> rows = await shop.db.db.rawQuery(
      'SELECT business_date AS d FROM order_voids WHERE order_id = ?',
      <Object?>[sold.id],
    );
    expect(rows.single['d'], '2026-03-14');
  });

  test('it cannot be moved into the future', () async {
    final CompletedOrder sold = await aSale();
    expect(
      () => shop.sales.changeOrderDate(
        orderId: sold.id,
        day: DateTime(2026, 4, 1),
      ),
      throwsA(isA<BusinessRuleException>()),
    );
  });

  test('moving it to the day it is already on changes nothing', () async {
    final CompletedOrder sold = await aSale();
    final int before = await shop.countOf('audit_log');

    await shop.sales.changeOrderDate(
      orderId: sold.id,
      day: DateTime(2026, 3, 15),
    );

    expect(await shop.countOf('audit_log'), before);
  });

  test('it says in the trail where it came from', () async {
    final CompletedOrder sold = await aSale();
    await shop.sales.changeOrderDate(
      orderId: sold.id,
      day: DateTime(2026, 3, 14),
    );

    final List<Map<String, Object?>> rows = await shop.db.db.rawQuery(
      "SELECT summary FROM audit_log WHERE action = 'order_date_changed'",
    );
    expect(
      rows.single['summary'],
      '${sold.orderNo} moved from 2026-03-15 to 2026-03-14',
    );
  });
}
