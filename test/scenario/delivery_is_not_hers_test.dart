import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';
import 'package:kubo_pos/domain/services/business_report_service.dart';

import '../support/pos_fixture.dart';

/// The rider's fare passes through her hands and does not stop there.
///
/// She pays whoever delivers directly, so a delivery fee is not income.
/// Showing it inside revenue told her she had earned money that was never
/// hers, and — because gross profit already left it out — quietly
/// understated every margin in the app by whatever the rider charged.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late BusinessReportService business;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
    business = BusinessReportService(shop.db);
  });
  tearDown(() async => shop.close());

  /// One ₱129 Iced Black, with the rider's fare on top.
  Future<CompletedOrder> sell({Money? delivery}) async => shop.sell(
    OrderDraft(
      items: <DraftItem>[await shop.item('Iced Black', 'Large')],
      deliveryFee: delivery ?? Money.zero,
      paymentMethod: PaymentMethod.cash,
    ),
  );

  Future<SalesSummary> today() => shop.reports.forDay(shop.reports.today);

  test('the sales figure is the coffee alone', () async {
    await sell(delivery: Money.of(50));

    final SalesSummary day = await today();
    expect(day.salesRevenue, Money.of(129));
    expect(day.deliveryCollected, Money.of(50));
    // What she actually took in is still there, stated separately.
    expect(day.revenue, Money.of(179));
  });

  test('a delivered drink is not a bigger sale than a collected one', () async {
    await sell();
    await sell(delivery: Money.of(50));

    final SalesSummary day = await today();
    expect(day.salesRevenue, Money.of(258), reason: 'two drinks at ₱129');
    expect(
      day.averageOrderValue,
      Money.of(129),
      reason: 'the rider\'s fare is not part of what an order is worth',
    );
  });

  test('the margin is measured against the coffee', () async {
    final SalesSummary without = await today();
    expect(without.grossMarginBasisPoints, isNull);

    await sell();
    final SalesSummary plain = await today();
    final int? plainMargin = plain.grossMarginBasisPoints;
    expect(plainMargin, isNotNull);

    // The same drink again, delivered. The fare changes nothing about how
    // profitable the coffee is.
    await sell(delivery: Money.of(50));
    final SalesSummary delivered = await today();

    expect(
      delivered.grossMarginBasisPoints,
      plainMargin,
      reason: 'delivery must not move the margin',
    );
  });

  test('gross profit never counted it in the first place', () async {
    await sell(delivery: Money.of(50));

    final SalesSummary day = await today();
    expect(day.grossProfit, day.salesRevenue - day.cogs);
  });

  test('what is still owed is unaffected', () async {
    await sell(delivery: Money.of(50));
    final SalesSummary day = await today();
    expect(day.collected, Money.of(179), reason: 'she did take the fare');
  });

  test('money given back comes off the coffee, not the fare', () async {
    final CompletedOrder order = await sell(delivery: Money.of(50));
    final OrderRecord record = (await shop.sales.orderById(order.id))!;
    await shop.sales.refund(
      orderId: order.id,
      quantitiesByLineId: <int, int>{record.lines.single.id: 1},
      reason: 'Spilled',
    );

    final SalesSummary day = await today();
    expect(day.netRevenue, Money.zero, reason: '₱129 sold, ₱129 back');
  });

  test('the month says the same thing', () async {
    await sell(delivery: Money.of(50));

    final BusinessReport month = await business.forMonth(
      shop.reports.today.substring(0, 7),
    );
    expect(month.deliveryFees, Money.of(50));
    expect(month.netSales, Money.of(129));
  });

  test('an hour is not busier because the drinks were delivered', () async {
    await sell(delivery: Money.of(50));

    final List<BusyPeriod> hours = await business.byHour(
      shop.reports.today.substring(0, 7),
    );
    expect(hours.single.revenue, Money.of(129));
  });
}
