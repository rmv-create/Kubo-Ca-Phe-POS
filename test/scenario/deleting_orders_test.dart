import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// Taking an order off the books altogether.
///
/// For the rows that were never a sale: an evening of pressing buttons to
/// learn the app, carried into every report for ever if nothing can remove
/// them. Voiding is for a sale that happened and stopped counting; this is
/// for one that never happened at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late Ingredient beans;

  setUp(() async {
    shop = await PosFixture.open();
    // SAMPLE costs.
    beans = await shop.addIngredient(
      'Coffee beans',
      price: Money.of(1200),
      openingStock: 5000,
    );
    await shop.setRecipe('Iced Black', 'Large', <Ingredient, double>{
      beans: 20,
    });
  });

  tearDown(() async => shop.close());

  Future<CompletedOrder> sell({int quantity = 1}) async => shop.sell(
    OrderDraft(
      items: <DraftItem>[
        await shop.item('Iced Black', 'Large', quantity: quantity),
      ],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  test('a practice order can be taken off the books', () async {
    final CompletedOrder order = await sell();
    expect(await shop.sales.orderById(order.id), isNotNull);

    await shop.sales.deleteOrder(orderId: order.id, reason: 'Practice run');

    expect(await shop.sales.orderById(order.id), isNull);
  });

  test('the ingredients go back on the shelf', () async {
    final Quantity? before = await shop.stockOf(beans.id);
    await sell(quantity: 2);
    final Quantity? sold = await shop.stockOf(beans.id);
    expect(sold!.milli, lessThan(before!.milli));

    final CompletedOrder order = await sell();
    await shop.sales.deleteOrder(orderId: order.id, reason: 'Practice run');

    // Only the deleted order's coffee comes back, not the other two drinks'.
    expect(await shop.stockOf(beans.id), sold);
  });

  test('it stops counting in the day', () async {
    final CompletedOrder keep = await sell();
    final CompletedOrder bin = await sell();

    final String today = shop.reports.today;
    final SalesSummary before = await shop.reports.forDay(today);
    expect(before.orderCount, 2);

    await shop.sales.deleteOrder(orderId: bin.id, reason: 'Practice run');

    final SalesSummary after = await shop.reports.forDay(today);
    expect(after.orderCount, 1);
    expect(after.revenue, (await shop.sales.orderById(keep.id))!.total);
  });

  test(
    'an order that was already voided deletes without double-counting',
    () async {
      final CompletedOrder order = await sell();
      await shop.sales.voidOrder(orderId: order.id, reason: 'Rung by mistake');
      final Quantity? afterVoid = await shop.stockOf(beans.id);

      await shop.sales.deleteOrder(orderId: order.id, reason: 'Tidying up');

      expect(await shop.sales.orderById(order.id), isNull);
      expect(
        await shop.stockOf(beans.id),
        afterVoid,
        reason: 'the coffee went back once, not twice',
      );
    },
  );

  test('an order that was refunded is never deleted', () async {
    final CompletedOrder order = await sell();
    final OrderRecord record = (await shop.sales.orderById(order.id))!;
    await shop.sales.refund(
      orderId: order.id,
      quantitiesByLineId: <int, int>{record.lines.single.id: 1},
      reason: 'Customer changed their mind',
    );

    expect(
      () => shop.sales.deleteOrder(orderId: order.id, reason: 'Tidying up'),
      throwsA(isA<BusinessRuleException>()),
    );
    expect(await shop.sales.orderById(order.id), isNotNull);
  });

  test('it says why, and the saying survives the order', () async {
    final CompletedOrder order = await sell();
    await shop.sales.deleteOrder(orderId: order.id, reason: 'Practice run');

    final List<Map<String, Object?>> log = await shop.db.db.query(
      'audit_log',
      where: 'action = ?',
      whereArgs: <Object?>['order_deleted'],
    );
    expect(log.length, 1);
    expect(log.single['summary'], contains(order.orderNo));
    expect(log.single['summary'], contains('Practice run'));
  });

  test('the stock movements outlive the order they belonged to', () async {
    final CompletedOrder order = await sell();
    await shop.sales.deleteOrder(orderId: order.id, reason: 'Practice run');

    // The coffee really did leave the jar and really did go back, and that
    // stays true whatever happened to the receipt.
    final List<Map<String, Object?>> moves = await shop.db.db.rawQuery(
      'SELECT COUNT(*) n FROM inventory_movements WHERE ingredient_id = ?',
      <Object?>[beans.id],
    );
    expect(moves.first['n']! as int, greaterThan(1));
  });

  test('a reason is required', () async {
    final CompletedOrder order = await sell();
    expect(
      () => shop.sales.deleteOrder(orderId: order.id, reason: '  '),
      throwsA(isA<ValidationException>()),
    );
  });

  test('deleting something already gone says so', () async {
    expect(
      () => shop.sales.deleteOrder(orderId: 9999, reason: 'Practice run'),
      throwsA(isA<NotFoundException>()),
    );
  });
}
