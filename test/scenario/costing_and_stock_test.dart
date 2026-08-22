import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/recipe.dart';
import 'package:kubo_pos/domain/repositories/purchasing_repository.dart';

import '../support/pos_fixture.dart';

/// SAMPLE ingredient costs throughout. The owner has not supplied real ones,
/// so these exist only to prove the arithmetic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late Ingredient beans;
  late Ingredient milk;
  late Ingredient cup;

  setUp(() async {
    shop = await PosFixture.open();
    beans = await shop.addIngredient(
      'Coffee beans',
      price: Money.of(1200), // ₱1,200 / kg → ₱1.20 / g
      openingStock: 5000,
    );
    milk = await shop.addIngredient(
      'Full cream milk',
      unit: BaseUnit.millilitre,
      purchaseUnit: 'L',
      price: Money.of(90), // ₱90 / L → ₱0.09 / ml
      openingStock: 10000,
    );
    cup = await shop.addIngredient(
      'Grande cup',
      unit: BaseUnit.piece,
      purchaseUnit: 'pack',
      perPurchaseUnit: 50,
      price: Money.of(250), // ₱5.00 each
      openingStock: 200,
    );
  });

  tearDown(() async => shop.close());

  group('costing a drink', () {
    test('adds every ingredient at its own price', () async {
      await shop.setRecipe('Spanish Latte', 'Grande', <Ingredient, double>{
        beans: 18, // 18 g x ₱1.20 = ₱21.60
        milk: 240, // 240 ml x ₱0.09 = ₱21.60
        cup: 1, //   1 pc x ₱5.00 = ₱5.00
      });

      final CompletedOrder order = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      final Map<String, Object?> row = (await shop.db.db.query(
        'orders',
        where: 'id = ?',
        whereArgs: <Object?>[order.id],
      )).single;
      expect(Money(row['cogs_centavos']! as int), Money.of(48, 20));
      // 139.00 sold − 48.20 to make
      expect(Money(row['gross_profit_centavos']! as int), Money.of(90, 80));
    });

    test('rounds once for the whole drink, not per ingredient', () async {
      // SAMPLE: ₱4.00 per kg is ₱0.004 per gram — four tenths of a centavo.
      // Each line alone rounds to nothing; three of them round to one centavo.
      final Ingredient a = await shop.addIngredient(
        'Pinch A',
        price: Money.of(4),
      );
      final Ingredient b = await shop.addIngredient(
        'Pinch B',
        price: Money.of(4),
      );
      final Ingredient c = await shop.addIngredient(
        'Pinch C',
        price: Money.of(4),
      );
      await shop.setRecipe('Black', 'Grande', <Ingredient, double>{
        a: 1,
        b: 1,
        c: 1,
      });

      final CompletedOrder order = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      final Map<String, Object?> row = (await shop.db.db.query(
        'orders',
        where: 'id = ?',
        whereArgs: <Object?>[order.id],
      )).single;
      expect(row['cogs_centavos'], 1);
    });

    test(
      'an ingredient with no price makes the whole drink uncosted',
      () async {
        final Ingredient mystery = await shop.addIngredient('Unpriced syrup');
        await shop.setRecipe('Matcha Oat Latte', 'Grande', <Ingredient, double>{
          milk: 240,
          mystery: 10,
        });

        final CompletedOrder order = await shop.sell(
          OrderDraft(
            items: <DraftItem>[await shop.item('Matcha Oat Latte', 'Grande')],
            paymentMethod: PaymentMethod.cash,
          ),
        );
        final Map<String, Object?> row = (await shop.db.db.query(
          'orders',
          where: 'id = ?',
          whereArgs: <Object?>[order.id],
        )).single;
        expect(
          row['cogs_centavos'],
          0,
          reason: 'a partial cost would understate COGS',
        );
        expect(
          row['gross_profit_centavos'],
          0,
          reason: 'and would overstate profit',
        );
        expect(
          (await shop.db.db.query('order_items')).single['recipe_version_id'],
          isNull,
          reason: 'null marks the line as uncosted',
        );
      },
    );

    test('a drink with no recipe is not claimed as pure profit', () async {
      final CompletedOrder order = await shop.sell(
        OrderDraft(
          items: <DraftItem>[
            await shop.item('Vietnamese Egg Coffee', 'Grande'),
          ],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      final Map<String, Object?> row = (await shop.db.db.query(
        'orders',
        where: 'id = ?',
        whereArgs: <Object?>[order.id],
      )).single;
      expect(row['cogs_centavos'], 0);
      expect(row['gross_profit_centavos'], 0);
    });

    test('Small and Grande use their own recipes, not a multiplier', () async {
      await shop.setRecipe('Spanish Latte', 'Grande', <Ingredient, double>{
        beans: 18,
        milk: 240,
      });
      // A Small is not simply three quarters of a Grande.
      await shop.setRecipe('Spanish Latte', 'Small', <Ingredient, double>{
        beans: 14,
        milk: 160,
      });

      final Recipe grande = (await shop.recipeBook.recipeFor(
        productId: (await shop.product('Spanish Latte')).id,
        sizeId: (await shop.size('Spanish Latte', 'Grande')).size.id,
      ))!;
      final Recipe small = (await shop.recipeBook.recipeFor(
        productId: (await shop.product('Spanish Latte')).id,
        sizeId: (await shop.size('Spanish Latte', 'Small')).size.id,
      ))!;

      expect(grande.current!.cost, Money.of(43, 20));
      expect(small.current!.cost, Money.of(31, 20));
      expect(
        small.current!.cost!.centavos * 100 ~/ grande.current!.cost!.centavos,
        isNot(75),
        reason: 'the sizes are costed independently',
      );
    });
  });

  group('recipe versions', () {
    test(
      'editing a recipe leaves earlier orders costed as they were sold',
      () async {
        await shop.setRecipe('Spanish Latte', 'Grande', <Ingredient, double>{
          beans: 18,
          milk: 240,
        });
        final CompletedOrder march = await shop.sell(
          OrderDraft(
            items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
            paymentMethod: PaymentMethod.cash,
          ),
        );
        final Money marchCogs = Money(
          (await shop.db.db.query(
                'orders',
                where: 'id = ?',
                whereArgs: <Object?>[march.id],
              )).single['cogs_centavos']!
              as int,
        );
        expect(marchCogs, Money.of(43, 20));

        // Months later, the recipe changes.
        shop.clock.advance(const Duration(days: 90));
        await shop.setRecipe('Spanish Latte', 'Grande', <Ingredient, double>{
          beans: 22,
          milk: 300,
        });

        final CompletedOrder june = await shop.sell(
          OrderDraft(
            items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
            paymentMethod: PaymentMethod.cash,
          ),
        );
        final Money juneCogs = Money(
          (await shop.db.db.query(
                'orders',
                where: 'id = ?',
                whereArgs: <Object?>[june.id],
              )).single['cogs_centavos']!
              as int,
        );

        expect(juneCogs, Money.of(53, 40));
        // The March order still reads as it was sold.
        expect(
          Money(
            (await shop.db.db.query(
                  'orders',
                  where: 'id = ?',
                  whereArgs: <Object?>[march.id],
                )).single['cogs_centavos']!
                as int,
          ),
          marchCogs,
        );
      },
    );

    test('a price rise does not rewrite what past orders cost', () async {
      await shop.setRecipe('Spanish Latte', 'Grande', <Ingredient, double>{
        beans: 18,
      });
      final CompletedOrder before = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      expect(
        Money(
          (await shop.db.db.query(
                'orders',
                where: 'id = ?',
                whereArgs: <Object?>[before.id],
              )).single['cogs_centavos']!
              as int,
        ),
        Money.of(21, 60),
      );

      shop.clock.advance(const Duration(days: 30));
      await shop.purchasing.recordPurchase(
        lines: <PurchaseDraftLine>[
          PurchaseDraftLine(
            ingredientId: beans.id,
            quantityInPurchaseUnits: 1,
            totalCost: Money.of(1500), // beans went up
          ),
        ],
      );

      final CompletedOrder after = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      expect(
        Money(
          (await shop.db.db.query(
                'orders',
                where: 'id = ?',
                whereArgs: <Object?>[after.id],
              )).single['cogs_centavos']!
              as int,
        ),
        Money.of(27),
        reason: '18 g at the new ₱1.50/g',
      );
      // And the earlier order is untouched.
      expect(
        Money(
          (await shop.db.db.query(
                'orders',
                where: 'id = ?',
                whereArgs: <Object?>[before.id],
              )).single['cogs_centavos']!
              as int,
        ),
        Money.of(21, 60),
      );
    });
  });

  group('stock comes out when a drink is sold', () {
    setUp(() async {
      await shop.setRecipe('Spanish Latte', 'Grande', <Ingredient, double>{
        beans: 18,
        milk: 240,
        cup: 1,
      });
    });

    test('every ingredient is deducted, in the right amount', () async {
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      expect(
        await shop.stockOf(beans.id),
        Quantity.fromBase(4982, BaseUnit.gram),
      );
      expect(
        await shop.stockOf(milk.id),
        Quantity.fromBase(9760, BaseUnit.millilitre),
      );
      expect(
        await shop.stockOf(cup.id),
        Quantity.fromBase(199, BaseUnit.piece),
      );
    });

    test('two of the same drink take out twice as much', () async {
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[
            await shop.item('Spanish Latte', 'Grande', quantity: 2),
          ],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      expect(
        await shop.stockOf(cup.id),
        Quantity.fromBase(198, BaseUnit.piece),
      );
      expect(
        await shop.stockOf(beans.id),
        Quantity.fromBase(4964, BaseUnit.gram),
      );
    });

    test('every deduction is a ledger entry with before and after', () async {
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      final List<InventoryMovement> movements = await shop.stock.movements(
        ingredientId: beans.id,
      );
      final InventoryMovement sale = movements.firstWhere(
        (InventoryMovement m) => m.type == MovementType.sale,
      );
      expect(sale.before, Quantity.fromBase(5000, BaseUnit.gram));
      expect(sale.after, Quantity.fromBase(4982, BaseUnit.gram));
      expect(sale.delta, Quantity.fromBase(-18, BaseUnit.gram));
      expect(sale.value, Money.of(21, 60));
      expect(sale.reason, contains('Spanish Latte'));
    });

    test(
      'an ingredient marked not tracked is costed but never counted down',
      () async {
        final Ingredient ice = await shop.addIngredient(
          'Ice',
          price: Money.of(20),
          openingStock: 0,
          tracked: false,
        );
        await shop.setRecipe('Matcha Oat Latte', 'Grande', <Ingredient, double>{
          milk: 200,
          ice: 150,
        });

        final CompletedOrder order = await shop.sell(
          OrderDraft(
            items: <DraftItem>[await shop.item('Matcha Oat Latte', 'Grande')],
            paymentMethod: PaymentMethod.cash,
          ),
        );

        // 200 ml milk at ₱0.09 = ₱18.00, plus 150 g ice at ₱0.02 = ₱3.00.
        expect(
          Money(
            (await shop.db.db.query(
                  'orders',
                  where: 'id = ?',
                  whereArgs: <Object?>[order.id],
                )).single['cogs_centavos']!
                as int,
          ),
          Money.of(21),
          reason: 'ice is costed even though it is not counted',
        );
        expect(
          await shop.stock.movements(ingredientId: ice.id),
          isEmpty,
          reason: 'and no movement is written for it',
        );
      },
    );

    test('the cached balance can always be rebuilt from the ledger', () async {
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      // Corrupt the cache the way a bad restore might.
      await shop.db.db.update(
        'inventory',
        <String, Object?>{'qty_milli': 999},
        where: 'ingredient_id = ?',
        whereArgs: <Object?>[beans.id],
      );
      expect(
        await shop.stockOf(beans.id),
        Quantity.fromBase(0.999, BaseUnit.gram),
      );

      final int fixed = await shop.stock.rebuildBalances();
      expect(fixed, 1);
      expect(
        await shop.stockOf(beans.id),
        Quantity.fromBase(4982, BaseUnit.gram),
      );
    });
  });

  group('waste, purchases and counts', () {
    test('waste reduces stock and is valued at cost', () async {
      await shop.stock.recordWaste(
        ingredientId: milk.id,
        quantity: Quantity.fromBase(500, BaseUnit.millilitre),
        reason: WasteReason.spoiled,
        notes: 'Left out overnight',
      );

      expect(
        await shop.stockOf(milk.id),
        Quantity.fromBase(9500, BaseUnit.millilitre),
      );
      final WasteEntry entry = (await shop.stock.waste()).single;
      expect(entry.value, Money.of(45)); // 500 ml at ₱0.09
      expect(entry.reason, WasteReason.spoiled);
      expect(entry.notes, 'Left out overnight');
    });

    test('a delivery adds stock and becomes the new cost', () async {
      await shop.purchasing.recordPurchase(
        lines: <PurchaseDraftLine>[
          PurchaseDraftLine(
            ingredientId: beans.id,
            quantityInPurchaseUnits: 2,
            totalCost: Money.of(2600), // ₱1,300 / kg
          ),
        ],
      );

      expect(
        await shop.stockOf(beans.id),
        Quantity.fromBase(7000, BaseUnit.gram),
      );
      final Ingredient updated = (await shop.stock.ingredientById(beans.id))!;
      expect(updated.purchasePrice, Money.of(1300));
      expect((await shop.stock.costHistory(beans.id)).length, 2);
    });

    test('a stock count adjusts, and records why', () async {
      await shop.stock.applyStockCount(
        counted: <int, Quantity>{
          beans.id: Quantity.fromBase(4800, BaseUnit.gram),
        },
      );
      expect(
        await shop.stockOf(beans.id),
        Quantity.fromBase(4800, BaseUnit.gram),
      );

      final List<InventoryMovement> movements = await shop.stock.movements(
        ingredientId: beans.id,
      );
      final InventoryMovement adjustment = movements.first;
      expect(adjustment.type, MovementType.adjustment);
      expect(adjustment.delta, Quantity.fromBase(-200, BaseUnit.gram));
      expect(adjustment.reason, 'Stock count');
    });

    test('a count that matches changes nothing', () async {
      final int before = await shop.countOf('stock_counts');
      final int changed = await shop.stock.applyStockCount(
        counted: <int, Quantity>{
          beans.id: Quantity.fromBase(5000, BaseUnit.gram),
        },
      );
      expect(changed, 0);
      expect(
        await shop.countOf('stock_counts'),
        before,
        reason: 'a count with no differences is not worth recording',
      );
    });

    test('alerts fire at the levels she set, critical before low', () async {
      final Ingredient updated = (await shop.stock.ingredientById(beans.id))!;
      await shop.stock.updateIngredient(
        updated.copyWith(
          reorderThreshold: Quantity.fromBase(2000, BaseUnit.gram),
          criticalThreshold: Quantity.fromBase(1000, BaseUnit.gram),
        ),
      );

      Ingredient current = (await shop.stock.ingredientById(beans.id))!;
      expect(current.status, StockStatus.ok);

      await shop.stock.applyStockCount(
        counted: <int, Quantity>{
          beans.id: Quantity.fromBase(1500, BaseUnit.gram),
        },
      );
      current = (await shop.stock.ingredientById(beans.id))!;
      expect(current.status, StockStatus.low);

      await shop.stock.applyStockCount(
        counted: <int, Quantity>{
          beans.id: Quantity.fromBase(800, BaseUnit.gram),
        },
      );
      current = (await shop.stock.ingredientById(beans.id))!;
      expect(current.status, StockStatus.critical);

      final List<Ingredient> alerts = await shop.stock.stockAlerts();
      expect(alerts.first.id, beans.id);
      expect(alerts.first.status, StockStatus.critical);
    });
  });
}
