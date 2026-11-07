import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/data/db/seed/pantry_seed.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// Her own ingredients, costs, stock levels and recipes, loaded from the
/// worksheet she filled in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
  });
  tearDown(() async => shop.close());

  Future<Ingredient> ingredient(String name) async =>
      (await shop.stock.ingredients()).firstWhere(
        (Ingredient i) => i.name == name,
      );

  group('what she buys', () {
    test('every ingredient on her sheet is there, with its cost', () async {
      final List<Ingredient> all = await shop.stock.ingredients();

      expect(all, hasLength(PantrySeed.ingredients.length));
      expect(all.map((Ingredient i) => i.name), contains('Sang Tao 1'));
      expect(all.map((Ingredient i) => i.name), contains('Oatside'));
    });

    test('a pack price becomes a price per gram', () async {
      // Sang Tao 1: ₱317 for 340 g.
      final Ingredient coffee = await ingredient('Sang Tao 1');

      expect(coffee.baseUnit, BaseUnit.gram);
      expect(coffee.purchaseUnitSize.inBaseUnits, 340);
      // ₱317 ÷ 340 g = ₱0.9324 a gram, held as centavos per 1000 g.
      final List<IngredientCost> history = await shop.stock.costHistory(
        coffee.id,
      );
      expect(history.single.cost.centavosPer1000Base, 93235);
    });

    test('what was on the shelf is on the shelf', () async {
      expect((await ingredient('Oatside')).onHand!.inBaseUnits, 9000);
      expect((await ingredient('Straw')).onHand!.inBaseUnits, 200);
    });

    test('the things she does not count down are not counted down', () async {
      // Ice, water and the gas are costed but never tracked, exactly as she
      // answered on the sheet.
      expect((await ingredient('Ice')).isInventoryTracked, isFalse);
      expect((await ingredient('Water')).isInventoryTracked, isFalse);
      expect((await ingredient('Sang Tao 1')).isInventoryTracked, isTrue);
    });

    test('her reorder and panic levels came across', () async {
      final Ingredient coffee = await ingredient('Sang Tao 1');

      expect(coffee.reorderThreshold.inBaseUnits, 1700);
      expect(coffee.criticalThreshold.inBaseUnits, 1020);
    });
  });

  group('what goes into each drink', () {
    test('every drink on the menu is costed, at both sizes', () async {
      final List<OrderRecord> sold = <OrderRecord>[];
      for (final String drink in <String>[
        'Iced Black',
        'Spanish Latte',
        'Cinnamon Oat Latte',
        'Caramel Macchiato',
        'Matcha Oat Latte',
        'Sea Salt Matcha Oat Latte',
        'Ca Phe Sua Da',
        'Ca Phe Muoi',
        'Ca Phe Trung',
      ]) {
        for (final String size in <String>['Grande', 'Small']) {
          final CompletedOrder done = await shop.sell(
            OrderDraft(
              items: <DraftItem>[await shop.item(drink, size)],
              paymentMethod: PaymentMethod.cash,
            ),
          );
          sold.add((await shop.sales.orderById(done.id))!);
        }
      }

      for (final OrderRecord order in sold) {
        expect(
          order.isCosted,
          isTrue,
          reason: '${order.lines.single.title} has no recipe',
        );
        expect(
          order.cogs.isPositive,
          isTrue,
          reason: '${order.lines.single.title} cost nothing to make',
        );
      }
    });

    test('a Grande Spanish Latte costs what her sheet says', () async {
      final CompletedOrder done = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      final OrderRecord order = (await shop.sales.orderById(done.id))!;

      // 22 g coffee at ₱0.932, 130 g water, 32 g condensed, 180 g ice,
      // 85 g fresh milk, 20 g evaporada, ₱10 of gas, a ₱4.58 cup, a ₱0.58
      // cover and a ₱0.48 straw — the same ₱63.83 her own sheet works out.
      expect(order.cogs, Money.of(63, 83));
      expect(order.total, Money.of(139));
      expect(order.grossProfit, Money.of(75, 17));
    });

    test('making a drink takes its ingredients off the shelf', () async {
      final double before = (await ingredient(
        'Sang Tao 1',
      )).onHand!.inBaseUnits;

      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      expect((await ingredient('Sang Tao 1')).onHand!.inBaseUnits, before - 22);
      // The cup and the straw too — they cost money.
      expect((await ingredient('Straw')).onHand!.inBaseUnits, 199);
      expect((await ingredient('Large cup 16oz')).onHand!.inBaseUnits, 199);
    });

    test('an ingredient listed twice in one drink is added up', () async {
      // Her Caramel Macchiato lists fresh milk twice — 85 g in the drink and
      // 15 g in the cold foam. The recipe must hold 100 g, not 15.
      final PantryRecipe macchiato = PantrySeed.recipes.firstWhere(
        (PantryRecipe r) =>
            r.drink == 'Caramel Macchiato' && r.size == 'Grande',
      );

      expect(macchiato.lines['Alaska Fresh Milk'], 100);
      expect(macchiato.lines['Vinamilk Condensed'], 17);
    });
  });

  group('seeding', () {
    test('it never runs twice', () async {
      expect(await PantrySeeder(shop.db, shop.clock).seedIfEmpty(), isFalse);
      expect(
        await shop.stock.ingredients(),
        hasLength(PantrySeed.ingredients.length),
      );
    });
  });
}
