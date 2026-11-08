import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/repositories/purchasing_repository.dart';
import 'package:kubo_pos/domain/services/business_report_service.dart';
import 'package:kubo_pos/domain/services/discount_engine.dart';

import '../support/pos_fixture.dart';

/// The month, read the way a shop owner reads it.
///
/// One of the ways she takes money that the app does not keep a constant
/// for: Maya, MariBank and BPI live in the database, added when she listed
/// them, and are named here by the code the payment carries.
PaymentMethod _method(String code, String label) =>
    PaymentMethod(code: code, label: label, needsConfirmation: true);

/// SAMPLE figures throughout: a made-up month, built to prove the
/// arithmetic rather than to describe her trade.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late BusinessReportService reports;
  late Ingredient beans;

  setUp(() async {
    shop = await PosFixture.open();
    reports = BusinessReportService(shop.db);
    beans = await shop.addIngredient(
      'Coffee',
      price: Money.of(900),
      openingStock: 2000,
    );
    await shop.setRecipe('Spanish Latte', 'Large', <Ingredient, double>{
      beans: 20,
    });
  });

  tearDown(() async => shop.close());

  Future<void> sell({
    PaymentMethod method = PaymentMethod.cash,
    bool unpaid = false,
    Money? discountOff,
  }) async {
    await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: unpaid ? null : method,
        unpaid: unpaid,
        paymentConfirmed: method != PaymentMethod.cash && !unpaid,
        discountKind: discountOff == null ? null : DiscountKind.other,
        discountAmountOverride: discountOff,
        discountReason: discountOff == null ? null : 'Friend',
      ),
    );
  }

  String month() => shop.clock.now().toIso8601String().substring(0, 7);

  group('what the month earned', () {
    test('the top line is what she charged, not what the menu says',
        () async {
      await sell();
      await sell(discountOff: Money.of(20));

      final BusinessReport r = await reports.forMonth(month());

      expect(r.grossSales, Money.of(278), reason: '2 × ₱139 at menu price');
      expect(r.discounts, Money.of(20));
      expect(r.revenue, Money.of(258));
      expect(r.netSales, Money.of(258));
    });

    test('gross profit is what she charged less what it cost to make',
        () async {
      await sell();

      final BusinessReport r = await reports.forMonth(month());

      // 20 g of beans at ₱900/kg is ₱18.
      expect(r.cogs, Money.of(18));
      expect(r.grossProfit, Money.of(121));
      expect(r.grossMarginBp, 8705, reason: '121 ÷ 139 = 87.05%');
    });

    test('spilling coffee comes off the trading profit', () async {
      await sell();
      await shop.stock.recordWaste(
        ingredientId: beans.id,
        quantity: Quantity.fromBase(100, BaseUnit.gram),
        reason: WasteReason.spill,
      );

      final BusinessReport r = await reports.forMonth(month());

      expect(r.waste, Money.of(90), reason: '100 g at ₱900/kg');
      expect(r.tradingProfit, r.grossProfit - Money.of(90));
    });

    test('per day divides by days she actually traded, not by 30', () async {
      await sell();
      await sell();
      shop.clock.advance(const Duration(days: 2));
      await sell();

      final BusinessReport r = await reports.forMonth(month());

      expect(r.tradingDays, 2);
      expect(r.perDay, Money.of(208, 50), reason: '₱417 over two days');
      expect(r.perOrder, Money.of(139));
    });
  });

  group('where the money came in', () {
    test('every way of paying is counted as itself', () async {
      await sell();
      await sell(method: PaymentMethod.gcash);
      await sell(method: _method('maya', 'Maya'));
      await sell(method: _method('maribank', 'MariBank'));
      await sell(method: _method('bpi', 'BPI'));

      final BusinessReport r = await reports.forMonth(month());

      // This is the bug this report was written against: Maya, MariBank
      // and BPI used to be added to the GCash line, so she would have
      // reconciled a GCash figure that was three other things as well.
      expect(r.receivedByMethod['cash'], Money.of(139));
      expect(r.receivedByMethod['gcash'], Money.of(139));
      expect(r.receivedByMethod['maya'], Money.of(139));
      expect(r.receivedByMethod['maribank'], Money.of(139));
      expect(r.receivedByMethod['bpi'], Money.of(139));
      expect(r.received, Money.of(695));
    });

    test('an unpaid order is a sale, and is not money', () async {
      await sell();
      await sell(unpaid: true);

      final BusinessReport r = await reports.forMonth(month());

      expect(r.revenue, Money.of(278), reason: 'both are sales');
      expect(r.received, Money.of(139), reason: 'only one is money');
      expect(r.stillOwed, Money.of(139));
    });
  });

  group('cash in and cash out', () {
    test('stock bought is cash out, and is not a cost of this coffee',
        () async {
      await sell();
      await shop.purchasing.recordPurchase(
        lines: <PurchaseDraftLine>[
          PurchaseDraftLine(
            ingredientId: beans.id,
            quantityInPurchaseUnits: 2,
            totalCost: Money.of(1800),
          ),
        ],
      );

      final BusinessReport r = await reports.forMonth(month());

      expect(r.spentOnStock, Money.of(1800));
      expect(r.netCashMovement, Money.of(139) - Money.of(1800));
      // Most of those beans are still on the shelf, so they are not what
      // this month's coffee cost. The profit must not move.
      expect(r.cogs, Money.of(18));
      expect(r.grossProfit, Money.of(121));
    });

    test('what is on the shelf is valued at what it cost', () async {
      final BusinessReport r = await reports.forMonth(month());
      expect(r.stockOnHand, Money.of(1800), reason: '2 kg at ₱900');
    });
  });

  group('when the shop is busy', () {
    test('counts the orders by the hour she took them', () async {
      await sell();
      await sell();

      final List<BusyPeriod> hours = await reports.byHour(month());

      expect(hours, isNotEmpty);
      expect(
        hours.fold<int>(0, (int a, BusyPeriod b) => a + b.orderCount),
        2,
      );
    });

    test('and by the day of the week', () async {
      await sell();
      final List<BusyPeriod> days = await reports.byWeekday(month());

      expect(days, hasLength(1));
      expect(days.first.orderCount, 1);
      expect(days.first.revenue, Money.of(139));
    });
  });

  group('what she gave away', () {
    test('discounts are grouped by what she called them', () async {
      await sell(discountOff: Money.of(20));
      await sell(discountOff: Money.of(30));

      final List<DiscountGiven> given = await reports.discountsGiven(month());

      expect(given, hasLength(1));
      expect(given.first.label, 'Friend');
      expect(given.first.times, 2);
      expect(given.first.total, Money.of(50));
    });

    test('waste is grouped by why', () async {
      await shop.stock.recordWaste(
        ingredientId: beans.id,
        quantity: Quantity.fromBase(50, BaseUnit.gram),
        reason: WasteReason.spill,
      );
      await shop.stock.recordWaste(
        ingredientId: beans.id,
        quantity: Quantity.fromBase(100, BaseUnit.gram),
        reason: WasteReason.expired,
      );

      final List<WasteByReason> waste = await reports.wasteByReason(month());

      expect(waste.first.reason, 'expired', reason: 'worst first');
      expect(waste.first.total, Money.of(90));
      expect(waste.last.reason, 'spill');
    });
  });

  group('an empty month', () {
    test('reads as zero rather than failing', () async {
      final BusinessReport r = await reports.forMonth('2020-01');

      expect(r.revenue, Money.zero);
      expect(r.tradingDays, 0);
      expect(r.perDay, isNull);
      expect(r.grossMarginBp, isNull);
      expect(r.received, Money.zero);
    });
  });
}
