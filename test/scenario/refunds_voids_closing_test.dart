import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late Ingredient beans;
  late Ingredient cup;

  setUp(() async {
    shop = await PosFixture.open();
    // SAMPLE costs.
    beans = await shop.addIngredient(
      'Coffee beans',
      price: Money.of(1200),
      openingStock: 5000,
    );
    cup = await shop.addIngredient(
      'Grande cup',
      unit: BaseUnit.piece,
      purchaseUnit: 'pack',
      perPurchaseUnit: 50,
      price: Money.of(250),
      openingStock: 200,
    );
    await shop.setRecipe('Black', 'Grande', <Ingredient, double>{
      beans: 20, // ₱24.00
      cup: 1, //  ₱5.00
    });
  });

  tearDown(() async => shop.close());

  Future<CompletedOrder> sellBlack({
    int quantity = 1,
    Customer? customer,
  }) async => shop.sell(
    OrderDraft(
      customer: customer,
      items: <DraftItem>[
        await shop.item('Black', 'Grande', quantity: quantity),
      ],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  group('refunds', () {
    test('give money back without deleting the sale', () async {
      final CompletedOrder order = await sellBlack(quantity: 2);
      final OrderRecord before = (await shop.sales.orderById(order.id))!;
      expect(before.total, Money.of(278));

      await shop.sales.refund(
        orderId: order.id,
        quantitiesByLineId: <int, int>{before.lines.single.id: 1},
        reason: 'Customer changed their mind',
      );

      final OrderRecord after = (await shop.sales.orderById(order.id))!;
      expect(after.total, Money.of(278), reason: 'the sale is unchanged');
      expect(after.refunded, Money.of(139));
      expect(after.netTotal, Money.of(139));
      expect(after.status, 'completed');
      expect(after.lines.single.refundedQuantity, 1);
      expect(after.lines.single.remainingQuantity, 1);
    });

    test('a full refund still leaves the order on the record', () async {
      final CompletedOrder order = await sellBlack();
      final OrderRecord before = (await shop.sales.orderById(order.id))!;
      await shop.sales.refund(
        orderId: order.id,
        quantitiesByLineId: <int, int>{before.lines.single.id: 1},
        reason: 'Wrong drink',
      );

      final OrderRecord after = (await shop.sales.orderById(order.id))!;
      expect(after.isFullyRefunded, isTrue);
      expect(after.netTotal, Money.zero);
      expect(await shop.countOf('orders'), 1);
      expect(await shop.countOf('order_items'), 1);
    });

    test('the same drink cannot be refunded twice', () async {
      final CompletedOrder order = await sellBlack();
      final OrderRecord before = (await shop.sales.orderById(order.id))!;
      await shop.sales.refund(
        orderId: order.id,
        quantitiesByLineId: <int, int>{before.lines.single.id: 1},
        reason: 'First',
      );

      await expectLater(
        shop.sales.refund(
          orderId: order.id,
          quantitiesByLineId: <int, int>{before.lines.single.id: 1},
          reason: 'Again',
        ),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('a refund needs a reason', () async {
      final CompletedOrder order = await sellBlack();
      final OrderRecord before = (await shop.sales.orderById(order.id))!;
      await expectLater(
        shop.sales.refund(
          orderId: order.id,
          quantitiesByLineId: <int, int>{before.lines.single.id: 1},
          reason: '   ',
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('stock only goes back if the drink was never made', () async {
      final CompletedOrder order = await sellBlack();
      final OrderRecord record = (await shop.sales.orderById(order.id))!;
      final Quantity afterSale = (await shop.stockOf(beans.id))!;
      expect(afterSale, Quantity.fromBase(4980, BaseUnit.gram));

      // Made and handed over, then refunded — the beans are gone either way.
      await shop.sales.refund(
        orderId: order.id,
        quantitiesByLineId: <int, int>{record.lines.single.id: 1},
        reason: 'Did not like it',
      );
      expect(await shop.stockOf(beans.id), afterSale);
    });

    test('stock does go back when asked for', () async {
      final CompletedOrder order = await sellBlack(quantity: 2);
      final OrderRecord record = (await shop.sales.orderById(order.id))!;
      expect(
        await shop.stockOf(beans.id),
        Quantity.fromBase(4960, BaseUnit.gram),
      );

      // One of the two was never made.
      await shop.sales.refund(
        orderId: order.id,
        quantitiesByLineId: <int, int>{record.lines.single.id: 1},
        reason: 'Never made',
        restockIngredients: true,
      );
      expect(
        await shop.stockOf(beans.id),
        Quantity.fromBase(4980, BaseUnit.gram),
        reason: 'only the refunded share comes back',
      );
      expect(
        await shop.stockOf(cup.id),
        Quantity.fromBase(199, BaseUnit.piece),
      );
    });

    test('a refund is netted off the day, not erased from it', () async {
      final CompletedOrder order = await sellBlack();
      final OrderRecord record = (await shop.sales.orderById(order.id))!;
      await shop.sales.refund(
        orderId: order.id,
        quantitiesByLineId: <int, int>{record.lines.single.id: 1},
        reason: 'Spilled it myself',
      );

      final SalesSummary day = await shop.reports.forDay(order.businessDate);
      expect(day.revenue, Money.of(139), reason: 'the sale still happened');
      expect(day.refunds, Money.of(139), reason: 'and so did the refund');
      expect(day.netRevenue, Money.zero);
      expect(day.orderCount, 1);
    });
  });

  group('voids', () {
    test('stop an order counting without deleting it', () async {
      final CompletedOrder order = await sellBlack();
      await shop.sales.voidOrder(orderId: order.id, reason: 'Rung up twice');

      final OrderRecord after = (await shop.sales.orderById(order.id))!;
      expect(after.isVoided, isTrue);
      expect(after.voidReason, 'Rung up twice');
      expect(after.netTotal, Money.zero);
      expect(await shop.countOf('orders'), 1, reason: 'still on the record');

      final SalesSummary day = await shop.reports.forDay(order.businessDate);
      expect(day.orderCount, 0);
      expect(day.revenue, Money.zero);
      expect(day.voids, Money.of(139));
    });

    test('put every ingredient back', () async {
      final CompletedOrder order = await sellBlack(quantity: 3);
      expect(
        await shop.stockOf(beans.id),
        Quantity.fromBase(4940, BaseUnit.gram),
      );

      await shop.sales.voidOrder(orderId: order.id, reason: 'Mistake');

      expect(
        await shop.stockOf(beans.id),
        Quantity.fromBase(5000, BaseUnit.gram),
        reason: 'nothing was actually made',
      );
      expect(
        await shop.stockOf(cup.id),
        Quantity.fromBase(200, BaseUnit.piece),
      );
    });

    test('do not credit a customer with a drink they never got', () async {
      final int mariaId = await shop.customers.create(name: 'Maria Santos');
      final Customer maria = (await shop.customers.byId(mariaId))!;
      final CompletedOrder order = await sellBlack(customer: maria);

      expect((await shop.customers.byId(mariaId))!.orderCount, 1);
      await shop.sales.voidOrder(orderId: order.id, reason: 'Wrong customer');

      final Customer after = (await shop.customers.byId(mariaId))!;
      expect(after.orderCount, 0);
      expect(after.totalSpend, Money.zero);
    });

    test('cannot be voided twice', () async {
      final CompletedOrder order = await sellBlack();
      await shop.sales.voidOrder(orderId: order.id, reason: 'First');
      await expectLater(
        shop.sales.voidOrder(orderId: order.id, reason: 'Again'),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('an order that was already refunded cannot be voided', () async {
      final CompletedOrder order = await sellBlack(quantity: 2);
      final OrderRecord record = (await shop.sales.orderById(order.id))!;
      await shop.sales.refund(
        orderId: order.id,
        quantitiesByLineId: <int, int>{record.lines.single.id: 1},
        reason: 'Partial',
      );
      await expectLater(
        shop.sales.voidOrder(orderId: order.id, reason: 'Now void it'),
        throwsA(
          isA<BusinessRuleException>().having(
            (BusinessRuleException e) => e.message,
            'message',
            contains('already been refunded'),
          ),
        ),
      );
    });

    test('a voided order cannot then be refunded', () async {
      final CompletedOrder order = await sellBlack();
      final OrderRecord record = (await shop.sales.orderById(order.id))!;
      await shop.sales.voidOrder(orderId: order.id, reason: 'Mistake');
      await expectLater(
        shop.sales.refund(
          orderId: order.id,
          quantitiesByLineId: <int, int>{record.lines.single.id: 1},
          reason: 'Also refund',
        ),
        throwsA(isA<BusinessRuleException>()),
      );
    });
  });

  group('the daily figures', () {
    test('add up to the transactions behind them', () async {
      await sellBlack();
      await sellBlack(quantity: 2);
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.gcash,
          paymentConfirmed: true,
        ),
      );
      await shop.stock.recordWaste(
        ingredientId: beans.id,
        quantity: Quantity.fromBase(100, BaseUnit.gram),
        reason: WasteReason.spill,
      );

      final String today = shop.reports.today;
      final SalesSummary day = await shop.reports.forDay(today);

      expect(day.orderCount, 3);
      expect(day.drinkCount, 4);
      expect(day.revenue, Money.of(556)); // 139 + 278 + 139
      expect(day.cash, Money.of(417));
      expect(day.gcash, Money.of(139));
      expect(
        day.cash + day.gcash,
        day.revenue,
        reason: 'every peso is accounted for by one payment or the other',
      );
      expect(day.cogs, Money.of(116)); // 29.00 x 4
      expect(day.grossProfit, day.revenue - day.cogs);
      expect(day.waste, Money.of(120)); // 100 g at ₱1.20
    });

    test('closing locks the numbers in', () async {
      await sellBlack();
      final String today = shop.reports.today;

      final DailyClosing closing = await shop.reports.closeDay(today);
      expect(closing.summary.orderCount, 1);
      expect(closing.summary.revenue, Money.of(139));

      // A later sale belongs to the day it happened on; the closed record
      // keeps the figures as they stood.
      await sellBlack();
      final DailyClosing? stored = await shop.reports.closingFor(today);
      expect(stored!.summary.revenue, Money.of(139));
    });

    test('a day cannot be closed twice', () async {
      await sellBlack();
      final String today = shop.reports.today;
      await shop.reports.closeDay(today);
      await expectLater(
        shop.reports.closeDay(today),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('an uncosted order is counted and flagged, not hidden', () async {
      // Vietnamese Egg Coffee has no recipe.
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[
            await shop.item('Vietnamese Egg Coffee', 'Grande'),
          ],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      final SalesSummary day = await shop.reports.forDay(shop.reports.today);
      expect(day.orderCount, 1);
      expect(day.revenue, Money.of(159));
      expect(day.cogs, Money.zero);
      expect(day.grossProfit, Money.zero, reason: 'not the whole price');
      expect(day.uncostedOrders, 1, reason: 'and the owner is told');
    });
  });

  group('product performance', () {
    test('ranks by units sold, and separately by profit', () async {
      // A cheap high-margin drink against an expensive low-margin one.
      final Ingredient gold = await shop.addIngredient(
        'Expensive powder',
        price: Money.of(9000),
        openingStock: 1000,
      );
      await shop.setRecipe('Matcha Oat Latte', 'Grande', <Ingredient, double>{
        gold: 12, // ₱108.00 to make, sold at ₱139
        cup: 1,
      });

      for (int i = 0; i < 5; i++) {
        await shop.sell(
          OrderDraft(
            items: <DraftItem>[await shop.item('Matcha Oat Latte', 'Grande')],
            paymentMethod: PaymentMethod.cash,
          ),
        );
      }
      for (int i = 0; i < 3; i++) {
        await sellBlack();
      }

      final String month = shop.reports.thisMonth;
      final List<ProductPerformance> sellers = await shop.reports
          .productPerformance(month: month);
      final List<ProductPerformance> profitable = await shop.reports
          .mostProfitable(month: month);

      expect(
        sellers.first.productName,
        'Matcha Oat Latte',
        reason: 'five sold beats three',
      );
      expect(
        profitable.first.productName,
        'Black',
        reason: 'three at ₱110 profit beats five at ₱26',
      );
      expect(
        sellers.first.productName,
        isNot(profitable.first.productName),
        reason: 'the best seller and the best earner are different drinks',
      );
    });

    test('a refunded drink stops counting towards units and revenue', () async {
      final CompletedOrder order = await sellBlack(quantity: 3);
      final OrderRecord record = (await shop.sales.orderById(order.id))!;
      await shop.sales.refund(
        orderId: order.id,
        quantitiesByLineId: <int, int>{record.lines.single.id: 1},
        reason: 'One went back',
      );

      final ProductPerformance black = (await shop.reports.productPerformance(
        month: shop.reports.thisMonth,
      )).firstWhere((ProductPerformance p) => p.productName == 'Black');
      expect(black.unitsSold, 2);
      expect(black.revenue, Money.of(278));
    });
  });

  group('the audit trail', () {
    test('records everything that changes the books', () async {
      final CompletedOrder order = await sellBlack();
      final OrderRecord record = (await shop.sales.orderById(order.id))!;
      await shop.sales.refund(
        orderId: order.id,
        quantitiesByLineId: <int, int>{record.lines.single.id: 1},
        reason: 'Test',
      );
      await shop.stock.recordWaste(
        ingredientId: beans.id,
        quantity: Quantity.fromBase(50, BaseUnit.gram),
        reason: WasteReason.spill,
      );
      await shop.reports.closeDay(shop.reports.today);

      final List<Map<String, Object?>> log = await shop.db.db.query(
        'audit_log',
        orderBy: 'id',
      );
      final Set<String> actions = log
          .map((Map<String, Object?> r) => r['action']! as String)
          .toSet();
      expect(
        actions,
        containsAll(<String>[
          'order_completed',
          'refund_issued',
          'waste_recorded',
          'day_closed',
        ]),
      );
    });
  });
}
