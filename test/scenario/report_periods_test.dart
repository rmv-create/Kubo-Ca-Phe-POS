import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// The same figures over whichever stretch of trading she picks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async {
    shop = await PosFixture.open();
    // The shelf and the recipe exist before any of these sales: a recipe
    // written in March does not cost a drink sold in January, and the app
    // is right to say so.
    shop.clock.set(DateTime(2026, 1, 1, 8));
    final Ingredient beans = await shop.addIngredient(
      'Coffee beans',
      price: Money.of(1200),
      openingStock: 100000,
    );
    await shop.setRecipe('Iced Black', 'Large', <Ingredient, double>{
      beans: 20,
    });
  });

  tearDown(() async => shop.close());

  /// One ₱129 drink sold on the given day.
  Future<void> sellOn(DateTime day) async {
    shop.clock.set(day);
    await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Iced Black', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
  }

  /// January 10th, February 20th, March 1st, and twice on March 15th.
  Future<void> sellAcrossMonths() async {
    await sellOn(DateTime(2026, 1, 10, 10));
    await sellOn(DateTime(2026, 2, 20, 10));
    await sellOn(DateTime(2026, 3, 1, 10));
    await sellOn(DateTime(2026, 3, 15, 10));
    await sellOn(DateTime(2026, 3, 15, 11));
  }

  test('a day is just that day', () async {
    await sellAcrossMonths();

    final SalesSummary s = await shop.reports.forPeriod(
      ReportPeriod.day('2026-03-15'),
    );
    expect(s.orderCount, 2);
    expect(s.revenue, Money.of(258));
    expect(s.label, '2026-03-15');
  });

  test('a month is the whole month', () async {
    await sellAcrossMonths();

    final SalesSummary s = await shop.reports.forPeriod(
      ReportPeriod.month('2026-03'),
    );
    expect(s.orderCount, 3);
    expect(s.revenue, Money.of(387));
  });

  test('a stretch she picks takes both ends with it', () async {
    await sellAcrossMonths();

    // The 1st to the 15th: the March 1st drink and both on the 15th.
    final SalesSummary s = await shop.reports.forPeriod(
      ReportPeriod.between('2026-03-01', '2026-03-15'),
    );
    expect(s.orderCount, 3, reason: 'both ends are included');
    expect(s.label, '2026-03-01 to 2026-03-15');
  });

  test('a stretch can span months', () async {
    await sellAcrossMonths();

    final SalesSummary s = await shop.reports.forPeriod(
      ReportPeriod.between('2026-02-01', '2026-03-02'),
    );
    expect(s.orderCount, 2, reason: 'February 20th and March 1st');
  });

  test('dates given backwards are read the right way round', () async {
    await sellAcrossMonths();

    final SalesSummary s = await shop.reports.forPeriod(
      ReportPeriod.between('2026-03-15', '2026-03-01'),
    );
    expect(s.orderCount, 3);
    expect(s.label, '2026-03-01 to 2026-03-15');
  });

  test('all time is everything the shop ever sold', () async {
    await sellAcrossMonths();

    final SalesSummary s = await shop.reports.forPeriod(
      ReportPeriod.everything,
    );
    expect(s.orderCount, 5);
    expect(s.revenue, Money.of(645));
    expect(s.label, 'All time');
  });

  test('an empty stretch reports nothing rather than failing', () async {
    await sellAcrossMonths();

    final SalesSummary s = await shop.reports.forPeriod(
      ReportPeriod.between('2025-01-01', '2025-12-31'),
    );
    expect(s.orderCount, 0);
    expect(s.revenue, Money.zero);
  });

  group('the lists below follow the same stretch', () {
    test('best sellers are counted over the chosen days', () async {
      await sellAcrossMonths();

      final List<ProductPerformance> all = await shop.reports
          .productPerformance(period: ReportPeriod.everything);
      expect(all.single.unitsSold, 5);

      final List<ProductPerformance> oneDay = await shop.reports
          .productPerformance(period: ReportPeriod.day('2026-03-15'));
      expect(oneDay.single.unitsSold, 2);
    });

    test('and so does most profitable', () async {
      await sellAcrossMonths();

      final List<ProductPerformance> month = await shop.reports.mostProfitable(
        period: ReportPeriod.month('2026-03'),
      );
      expect(month.single.unitsSold, 3);
    });
  });

  test('the old day and month calls still mean what they did', () async {
    await sellAcrossMonths();

    expect((await shop.reports.forDay('2026-03-15')).orderCount, 2);
    expect((await shop.reports.forMonth('2026-03')).orderCount, 3);
  });

  test('waste and voids are narrowed by the same stretch', () async {
    await sellAcrossMonths();
    // A drink rung up by mistake on the 15th, undone the same day.
    shop.clock.set(DateTime(2026, 3, 15, 12));
    final CompletedOrder wrong = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Iced Black', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    await shop.sales.voidOrder(orderId: wrong.id, reason: 'Mistake');

    expect(
      (await shop.reports.forPeriod(ReportPeriod.day('2026-03-15'))).voids,
      Money.of(129),
    );
    expect(
      (await shop.reports.forPeriod(ReportPeriod.day('2026-03-01'))).voids,
      Money.zero,
    );
    expect(
      (await shop.reports.forPeriod(ReportPeriod.everything)).voids,
      Money.of(129),
    );
  });
}
