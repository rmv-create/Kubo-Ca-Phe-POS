import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// A customised drink is not the plain drink at a higher price. It is made
/// of different things, and the cost, the profit and the stock have to say so.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
  });
  tearDown(() async => shop.close());

  Future<OrderRecord> sell(
    String drink,
    String size, {
    List<DraftOption> options = const <DraftOption>[],
  }) async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item(drink, size, options: options)],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    return (await shop.sales.orderById(done.id))!;
  }

  Future<double> onHand(String name) async => (await shop.stock.ingredients())
      .firstWhere((Ingredient i) => i.name == name)
      .onHand!
      .inBaseUnits;

  group('an add-on she charges for', () {
    test('sea salt cold foam costs her what it is made of', () async {
      final OrderRecord plain = await sell('Spanish Latte', 'Large');
      final OrderRecord withFoam = await sell(
        'Spanish Latte',
        'Large',
        options: <DraftOption>[
          await shop.draftOption('extras', 'Sea Salt Cold Foam'),
        ],
      );

      // 20 g cream, 30 g fresh milk, 10 g condensed and 0.6 g salt — ₱11.12
      // of ingredients against the ₱20 she charges.
      expect(withFoam.total - plain.total, Money.of(20));
      expect(withFoam.cogs - plain.cogs, Money.of(11, 12));
      expect(withFoam.grossProfit - plain.grossProfit, Money.of(8, 88));
    });

    test('and comes out of the cream, the milk and the salt', () async {
      final double cream = await onHand('Nestle All Purpose Cream');
      final double milk = await onHand('Alaska Fresh Milk');

      await sell(
        'Spanish Latte',
        'Large',
        options: <DraftOption>[
          await shop.draftOption('extras', 'Sea Salt Cold Foam'),
        ],
      );

      expect(await onHand('Nestle All Purpose Cream'), cream - 20);
      // 85 g in the drink, 30 g in the foam.
      expect(await onHand('Alaska Fresh Milk'), milk - 115);
    });

    test('a gram of matcha is a gram of matcha', () async {
      final double matcha = await onHand('Matcha');
      final OrderRecord plain = await sell('Matcha Oat Latte', 'Large');
      final OrderRecord extra = await sell(
        'Matcha Oat Latte',
        'Large',
        options: <DraftOption>[await shop.draftOption('extras', '1g Matcha')],
      );

      expect(extra.total - plain.total, Money.of(15));
      // ₱466 for 50 g is ₱9.32 a gram, against ₱15 charged.
      expect(extra.cogs - plain.cogs, Money.of(9, 32));
      expect(await onHand('Matcha'), closeTo(matcha - 4.4 - 4.4 - 1, 0.001));
    });
  });

  group('substituting oat', () {
    test('takes the dairy out and puts oat in, by weight', () async {
      final double fresh = await onHand('Alaska Fresh Milk');
      final double evaporada = await onHand('Alaska Evaporada');
      final double oat = await onHand('Oatside');

      await sell(
        'Spanish Latte',
        'Large',
        options: <DraftOption>[await shop.draftOption('milk', 'Oat')],
      );

      // The drink holds 85 g fresh and 20 g evaporada; oat replaces both.
      expect(await onHand('Alaska Fresh Milk'), fresh);
      expect(await onHand('Alaska Evaporada'), evaporada);
      expect(await onHand('Oatside'), oat - 105);
    });

    test('costs the difference between the two milks, not nothing', () async {
      final OrderRecord plain = await sell('Spanish Latte', 'Large');
      final OrderRecord oat = await sell(
        'Spanish Latte',
        'Large',
        options: <DraftOption>[await shop.draftOption('milk', 'Oat')],
      );

      expect(oat.total - plain.total, Money.of(20));
      expect(
        oat.cogs > plain.cogs,
        isTrue,
        reason: 'oat is dearer than the milk it replaces',
      );
      // 105 g of oat at ₱0.16 against 85 g fresh at ₱0.095 and 20 g
      // evaporada at ₱0.0972.
      expect(oat.cogs - plain.cogs, Money.of(6, 78));
    });

    test('each drink swaps its own milk, not a flat amount', () async {
      final double oat = await onHand('Oatside');

      await sell(
        'Caramel Macchiato',
        'Large',
        options: <DraftOption>[await shop.draftOption('milk', 'Oat')],
      );

      // The Macchiato holds 100 g of fresh milk and 20 g evaporada — more
      // than the latte — so more oat goes in.
      expect(await onHand('Oatside'), oat - 120);
    });

    test('a drink already made with oat is unchanged and uncharged', () async {
      final OrderRecord plain = await sell('Matcha Oat Latte', 'Large');
      final OrderRecord oat = await sell(
        'Matcha Oat Latte',
        'Large',
        options: <DraftOption>[
          await shop.optionOn('Matcha Oat Latte', 'Large', 'milk', 'Oat'),
        ],
      );

      expect(oat.total, plain.total, reason: 'oat is what it is made of');
      expect(oat.cogs, plain.cogs);
    });
  });

  group('the figures that follow from it', () {
    test('the day adds up with customised drinks in it', () async {
      await sell(
        'Spanish Latte',
        'Large',
        options: <DraftOption>[
          await shop.draftOption('milk', 'Oat'),
          await shop.draftOption('extras', 'Sea Salt Cold Foam'),
        ],
      );

      final SalesSummary day = await shop.reports.forDay(shop.reports.today);

      expect(day.revenue, Money.of(179), reason: '139 + 20 + 20');
      expect(day.cogs, Money.of(81, 73));
      expect(day.grossProfit, day.revenue - day.cogs);
    });

    test('two of the same customised drink cost twice as much to '
        'make', () async {
      final CompletedOrder done = await shop.sell(
        OrderDraft(
          items: <DraftItem>[
            await shop.item(
              'Spanish Latte',
              'Large',
              quantity: 2,
              options: <DraftOption>[
                await shop.draftOption('extras', 'Sea Salt Cold Foam'),
              ],
            ),
          ],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      final OrderRecord two = (await shop.sales.orderById(done.id))!;
      final OrderRecord one = await sell(
        'Spanish Latte',
        'Large',
        options: <DraftOption>[
          await shop.draftOption('extras', 'Sea Salt Cold Foam'),
        ],
      );

      expect(two.cogs, one.cogs * 2);
      expect(two.total, one.total * 2);
    });

    test('a voided customised drink puts the add-on back too', () async {
      final double cream = await onHand('Nestle All Purpose Cream');
      final OrderRecord order = await sell(
        'Spanish Latte',
        'Large',
        options: <DraftOption>[
          await shop.draftOption('extras', 'Sea Salt Cold Foam'),
        ],
      );
      expect(await onHand('Nestle All Purpose Cream'), cream - 20);

      await shop.sales.voidOrder(orderId: order.id, reason: 'Rung by mistake');

      expect(await onHand('Nestle All Purpose Cream'), cream);
    });
  });
}
