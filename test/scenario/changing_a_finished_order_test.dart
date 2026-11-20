import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// Putting a finished order right when the customer changes their mind.
///
/// The order is not edited in place. A sale is a record of something that
/// happened, and the two phones agree precisely because those records are
/// written once; editing one would have no answer to "what if both phones
/// edit the same order", and would rewrite a day she has already closed.
///
/// So the drinks are handed back to the till and the old order is voided.
/// This covers the reading-back half: the till has to be able to put the
/// order on screen exactly as it was sold.
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

  test('voiding the old one puts the ingredients back', () async {
    final double before = await _beans(shop);
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    expect(await _beans(shop), lessThan(before));

    await shop.sales.voidOrder(
      orderId: done.id,
      reason: 'Changed by the owner',
    );

    expect(await _beans(shop), before);
  });

  test('and stops it counting, so only the new one is in the day', () async {
    final CompletedOrder first = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    await shop.sales.voidOrder(
      orderId: first.id,
      reason: 'Changed by the owner',
    );

    // What she rings up in its place.
    await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Iced Black', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    final SalesSummary day = await shop.reports.forDay(shop.reports.today);
    expect(day.orderCount, 1);
    expect(day.revenue, Money.of(129), reason: 'the Iced Black, not both');
  });

  test('the customer is not credited with the order she replaced', () async {
    final int id = await shop.customers.create(name: 'Tita Baby');
    final Customer who = (await shop.customers.byId(id))!;

    final CompletedOrder first = await shop.sell(
      OrderDraft(
        customer: who,
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    await shop.sales.voidOrder(
      orderId: first.id,
      reason: 'Changed by the owner',
    );
    await shop.sell(
      OrderDraft(
        customer: (await shop.customers.byId(id))!,
        items: <DraftItem>[await shop.item('Iced Black', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    expect((await shop.customers.byId(id))!.orderCount, 1);
    expect(
      (await shop.sales.orders(customerId: id, includeVoided: false)).length,
      1,
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
