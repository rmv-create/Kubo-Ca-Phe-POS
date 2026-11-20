import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// Putting a finished order right when the customer changes their mind.
///
/// She asked for the order itself to be editable: not voided and rung up
/// again under a second number, but corrected. So order 1111 taken at half
/// past ten stays order 1111 taken at half past ten, and only its contents
/// change.
///
/// What that has to get right: the day's takings show one sale at the new
/// total, the shelf holds what was actually made, the customer is credited
/// once, and the costs are those of the day it was sold.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
  });
  tearDown(() async => shop.close());

  test('the drinks come back as they were rung up', () async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Large', quantity: 2),
          await shop.item('Iced Black', 'Small', lineId: 'line-2'),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    final List<RepeatableLine> again = await shop.sales.drinksToRingAgain(
      done.id,
    );

    expect(again.length, 2);
    expect(again.first.quantity, 2);
    expect(again.last.quantity, 1);
  });

  test('and so do the customisations that were on them', () async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[
          await shop.item(
            'Spanish Latte',
            'Large',
            options: <DraftOption>[
              await shop.draftOption('extras', 'Sea Salt Cold Foam'),
              await shop.draftOption('sweetness', 'Less Sweet'),
            ],
          ),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    final RepeatableLine line = (await shop.sales.drinksToRingAgain(
      done.id,
    )).single;

    expect(line.optionIds.length, 2);
    // They are the ids of today's menu, so the till can select them again.
    final List<Map<String, Object?>> names = await shop.db.db.rawQuery(
      'SELECT name FROM customization_options WHERE id IN '
      '(${line.optionIds.join(',')}) ORDER BY name',
    );
    expect(names.map((Map<String, Object?> r) => r['name']), <String>[
      'Less Sweet',
      'Sea Salt Cold Foam',
    ]);
  });

  test('a corrected order keeps its number and its day', () async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    final CompletedOrder after = await shop.orders.revise(
      orderId: done.id,
      draft: OrderDraft(
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Large'),
          await shop.item('Iced Black', 'Small', lineId: 'line-2'),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
      settings: shop.settings,
    );

    expect(after.id, done.id);
    expect(after.orderNo, done.orderNo);
    expect(after.businessDate, done.businessDate);
    expect(after.createdAt, done.createdAt);
  });

  test('the day has one sale, at what it came to in the end', () async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    await shop.orders.revise(
      orderId: done.id,
      draft: OrderDraft(
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Large'),
          await shop.item('Iced Black', 'Large', lineId: 'line-2'),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
      settings: shop.settings,
    );

    final OrderRecord? order = await shop.sales.orderById(done.id);
    final SalesSummary day = await shop.reports.forDay(shop.reports.today);
    expect(day.orderCount, 1, reason: 'one sale, corrected — not two');
    expect(day.revenue, order!.total);
    expect(order.itemCount, 2);
  });

  test('nothing is voided and nothing is reversed', () async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    await shop.orders.revise(
      orderId: done.id,
      draft: OrderDraft(
        items: <DraftItem>[await shop.item('Iced Black', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
      settings: shop.settings,
    );

    expect(await shop.countOf('order_voids'), 0);
    final OrderRecord? order = await shop.sales.orderById(done.id);
    expect(order!.isVoided, isFalse);
    expect(order.itemCount, 1);
  });

  test('a drink added takes its ingredients off the shelf', () async {
    final double before = await _beans(shop);
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    final double afterOne = await _beans(shop);
    expect(afterOne, lessThan(before));

    await shop.orders.revise(
      orderId: done.id,
      draft: OrderDraft(
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Large', quantity: 2),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
      settings: shop.settings,
    );

    // Two of them now, so twice the milk of one — not three times.
    expect(afterOne - await _beans(shop), closeTo(before - afterOne, 0.001));
  });

  test('a drink taken off puts its ingredients back', () async {
    final double before = await _beans(shop);
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Large'),
          await shop.item('Spanish Latte', 'Small', lineId: 'line-2'),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    await shop.orders.revise(
      orderId: done.id,
      draft: OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
      settings: shop.settings,
    );

    final double justTheLarge = before - await _beans(shop);

    // The same as if the Large had been the only drink on it all along.
    final CompletedOrder control = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    expect(control.id, isNot(done.id));
    expect(
      justTheLarge,
      closeTo(before - await _beans(shop) - justTheLarge, 0.001),
    );
  });

  test('the stock ledger says why it moved', () async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    await shop.orders.revise(
      orderId: done.id,
      draft: OrderDraft(
        items: <DraftItem>[await shop.item('Iced Black', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
      settings: shop.settings,
    );

    final List<Map<String, Object?>> reasons = await shop.db.db.rawQuery(
      'SELECT DISTINCT reason FROM inventory_movements '
      "WHERE order_id = ? AND movement_type = 'correction'",
      <Object?>[done.id],
    );
    expect(reasons, isNotEmpty);
    expect(reasons.first['reason'], 'Changed \u00b7 ${done.orderNo}');
  });

  test('the customer is credited once, at the new total', () async {
    final int id = await shop.customers.create(name: 'Tita Baby');
    final Customer who = (await shop.customers.byId(id))!;

    final CompletedOrder done = await shop.sell(
      OrderDraft(
        customer: who,
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    await shop.orders.revise(
      orderId: done.id,
      draft: OrderDraft(
        customer: who,
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Large', quantity: 2),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
      settings: shop.settings,
    );

    final OrderRecord? order = await shop.sales.orderById(done.id);
    final Customer? after = await shop.customers.byId(id);
    expect(after!.orderCount, 1, reason: 'one visit, not two');
    expect(after.itemCount, 2);
    expect(after.totalSpend, order!.total);
  });

  test(
    'what they order counts the corrected drinks, not the old ones',
    () async {
      final int id = await shop.customers.create(name: 'James');
      final Customer who = (await shop.customers.byId(id))!;

      final CompletedOrder done = await shop.sell(
        OrderDraft(
          customer: who,
          items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      await shop.orders.revise(
        orderId: done.id,
        draft: OrderDraft(
          customer: who,
          items: <DraftItem>[await shop.item('Iced Black', 'Large')],
          paymentMethod: PaymentMethod.cash,
        ),
        settings: shop.settings,
      );

      final List<Map<String, Object?>> patterns = await shop.db.db.rawQuery(
        'SELECT p.occurrence_count AS n, pr.name AS drink '
        'FROM customer_order_patterns p '
        'JOIN products pr ON pr.id = p.product_id '
        'WHERE p.customer_id = ?',
        <Object?>[id],
      );
      expect(patterns.length, 1);
      expect(patterns.single['drink'], 'Iced Black');
    },
  );

  test('an order that has been refunded is left alone', () async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    final OrderRecord order = (await shop.sales.orderById(done.id))!;
    await shop.sales.refund(
      orderId: done.id,
      quantitiesByLineId: <int, int>{order.lines.single.id: 1},
      reason: 'Spilled it',
    );

    final OrderDraft instead = OrderDraft(
      items: <DraftItem>[await shop.item('Iced Black', 'Large')],
      paymentMethod: PaymentMethod.cash,
    );
    expect(
      () => shop.orders.revise(
        orderId: done.id,
        draft: instead,
        settings: shop.settings,
      ),
      throwsA(isA<BusinessRuleException>()),
    );
  });

  test('a voided order is rung up again, not corrected', () async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    await shop.sales.voidOrder(orderId: done.id, reason: 'Wrong order');

    final OrderDraft instead = OrderDraft(
      items: <DraftItem>[await shop.item('Iced Black', 'Large')],
      paymentMethod: PaymentMethod.cash,
    );
    expect(
      () => shop.orders.revise(
        orderId: done.id,
        draft: instead,
        settings: shop.settings,
      ),
      throwsA(isA<BusinessRuleException>()),
    );
  });

  test(
    'a drink taken off the menu since is left out, not guessed at',
    () async {
      final CompletedOrder done = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      // The line keeps its name for the receipt, but the drink it pointed at
      // is gone.
      await shop.db.db.rawUpdate(
        'UPDATE order_items SET product_id = NULL WHERE order_id = ?',
        <Object?>[done.id],
      );

      expect(await shop.sales.drinksToRingAgain(done.id), isEmpty);
    },
  );
}

Future<double> _beans(PosFixture shop) async => (await shop.stock.ingredients())
    .firstWhere((dynamic i) => i.name == 'Alaska Fresh Milk')
    .onHand!
    .inBaseUnits;
