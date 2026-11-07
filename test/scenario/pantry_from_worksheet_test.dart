import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/data/db/seed/pantry_seed.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/menu.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';
import 'package:sqflite_common/sqlite_api.dart';

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
        for (final String size in <String>['Large', 'Small']) {
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
          items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
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
          items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
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
        (PantryRecipe r) => r.drink == 'Caramel Macchiato' && r.size == 'Large',
      );

      expect(macchiato.lines['Alaska Fresh Milk'], 100);
      expect(macchiato.lines['Vinamilk Condensed'], 17);
    });
  });

  group('the corrected recipe sheet', () {
    test('Ca Phe Muoi is salt coffee again', () async {
      // The first sheet had its sea salt cream filed under Ca Phe Sua Da, and
      // left the Muoi with nothing in it but a cup and a straw.
      final PantryRecipe muoi = PantrySeed.recipes.firstWhere(
        (PantryRecipe r) => r.drink == 'Ca Phe Muoi' && r.size == 'Large',
      );
      final PantryRecipe suaDa = PantrySeed.recipes.firstWhere(
        (PantryRecipe r) => r.drink == 'Ca Phe Sua Da' && r.size == 'Large',
      );

      expect(muoi.lines.keys, contains('Sang Tao 1'));
      expect(muoi.lines.keys, contains('Sea Salt'));
      expect(muoi.lines.keys, contains('Nestle All Purpose Cream'));
      expect(suaDa.lines.keys, isNot(contains('Sea Salt')));
    });

    test('every size on every recipe is Small or Large', () async {
      expect(
        PantrySeed.recipes.map((PantryRecipe r) => r.size).toSet(),
        <String>{'Small', 'Large'},
      );
    });

    test('no drink is wildly out of line any more', () async {
      // The broken sheet gave the Muoi a 90% margin and the Sua Da 16%.
      // Nothing should now sit outside the band the rest of the menu is in.
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
        final CompletedOrder done = await shop.sell(
          OrderDraft(
            items: <DraftItem>[await shop.item(drink, 'Large')],
            paymentMethod: PaymentMethod.cash,
          ),
        );
        final OrderRecord order = (await shop.sales.orderById(done.id))!;
        final int margin =
            order.grossProfit.centavos * 100 ~/ order.total.centavos;

        expect(
          margin,
          inInclusiveRange(40, 60),
          reason: '$drink comes out at $margin%',
        );
      }
    });
  });

  group('a corrected sheet replaces what it should', () {
    /// Puts the shop back to where it was before the correction: the recipes
    /// written, but stamped as the earlier edition.
    Future<void> rewind() async {
      await shop.db.db.insert('app_settings', <String, Object?>{
        'key': SettingKeys.pantrySeedVersion,
        'value': '1',
        'updated_at': shop.clock.nowIso(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    Future<Set<String>> ingredientsOf(String drink, String size) async {
      final List<Map<String, Object?>> rows = await shop.db.db.rawQuery(
        '''
        SELECT i.name AS name
        FROM recipe_items ri
        JOIN recipe_versions v ON v.id = ri.recipe_version_id
        JOIN recipes r ON r.id = v.recipe_id
        JOIN products p ON p.id = r.product_id
        JOIN sizes s ON s.id = r.size_id
        JOIN ingredients i ON i.id = ri.ingredient_id
        WHERE p.name = ? AND s.name = ? AND v.effective_to IS NULL
        ''',
        <Object?>[drink, size],
      );
      return <String>{
        for (final Map<String, Object?> row in rows) row['name']! as String,
      };
    }

    test('a worksheet recipe is rewritten', () async {
      await rewind();
      // Stand in for the old, wrong transcription.
      await shop.db.db.rawDelete('''
        DELETE FROM recipe_items WHERE recipe_version_id IN (
          SELECT v.id FROM recipe_versions v
          JOIN recipes r ON r.id = v.recipe_id
          JOIN products p ON p.id = r.product_id
          WHERE p.name = 'Ca Phe Muoi')
        ''');
      expect(await ingredientsOf('Ca Phe Muoi', 'Large'), isEmpty);

      expect(await PantrySeeder(shop.db, shop.clock).seedIfEmpty(), isTrue);

      expect(
        await ingredientsOf('Ca Phe Muoi', 'Large'),
        contains('Sang Tao 1'),
      );
    });

    test('one she has edited herself is left alone', () async {
      final Product product = await shop.product('Ca Phe Muoi');
      final ProductSize size = await shop.size('Ca Phe Muoi', 'Large');
      final Ingredient coffee = (await shop.stock.ingredients()).firstWhere(
        (Ingredient i) => i.name == 'Sang Tao 1',
      );
      // Her own version 2: one ingredient, her quantity.
      await shop.recipeBook.saveVersion(
        productId: product.id,
        sizeId: size.size.id,
        lines: <int, Quantity>{coffee.id: Quantity.fromBase(99, BaseUnit.gram)},
      );
      await rewind();

      await PantrySeeder(shop.db, shop.clock).seedIfEmpty();

      expect(await ingredientsOf('Ca Phe Muoi', 'Large'), <String>{
        'Sang Tao 1',
      }, reason: 'her version stands');
    });

    test('it does not run again once the edition is stamped', () async {
      expect(await PantrySeeder(shop.db, shop.clock).seedIfEmpty(), isFalse);
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
