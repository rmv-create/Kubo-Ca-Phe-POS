import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/money/unit_cost.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/repositories/purchasing_repository.dart';
import 'package:kubo_pos/domain/services/costing_engine.dart';
import 'package:kubo_pos/domain/services/moving_average_cost.dart';

import '../support/pos_fixture.dart';

/// What the stock on the shelf cost, and what it costs to replace it, are two
/// different questions. These tests pin down the first one.
///
/// SAMPLE figures throughout — ₱125 and ₱115 a litre are the owner's own
/// worked example from a conversation, not a recorded purchase of hers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture pos;

  setUp(() async {
    pos = await PosFixture.open();
    pos.settings = pos.settings.copyWith(
      costingMethod: CostingMethod.weightedAverage,
    );
  });

  tearDown(() async => pos.close());

  /// The cost one litre is carried at, right now.
  Future<int> perLitre(Ingredient milk) async {
    final UnitCost? cost = await CostingEngine(pos.db.db).costOfIngredient(
      milk.id,
      method: CostingMethod.weightedAverage,
      asOf: pos.clock.now(),
    );
    return cost!.centavosPer1000Base;
  }

  Future<void> deliver(
    Ingredient milk, {
    required double cartons,
    required Money total,
  }) async {
    await pos.purchasing.recordPurchase(
      lines: <PurchaseDraftLine>[
        PurchaseDraftLine(
          ingredientId: milk.id,
          quantityInPurchaseUnits: cartons,
          totalCost: total,
        ),
      ],
    );
    pos.clock.advance(const Duration(hours: 1));
  }

  Future<Ingredient> freshMilk({double openingStock = 0}) => pos.addIngredient(
    'Fresh Milk',
    unit: BaseUnit.millilitre,
    purchaseUnit: 'carton',
    perPurchaseUnit: 1000,
    price: const Money(12500),
    openingStock: openingStock,
  );

  group('a delivery at a new price', () {
    test('averages against what is still on the shelf', () async {
      // Six litres she already has, bought at ₱125.
      final Ingredient milk = await freshMilk(openingStock: 6000);
      expect(await perLitre(milk), 12500);

      // Ten more at ₱115 — ₱1,150 the lot.
      await deliver(milk, cartons: 10, total: const Money(115000));

      // (6 × 125) + (10 × 115) over 16 litres.
      expect(await perLitre(milk), 11875);
      expect(
        await pos.stockOf(milk.id),
        Quantity.fromBase(16000, BaseUnit.millilitre),
      );
    });

    test('is dearer when less of the cheap stock is left', () async {
      final Ingredient milk = await freshMilk(openingStock: 1000);
      await deliver(milk, cartons: 10, total: const Money(115000));

      // (1 × 125) + (10 × 115) over 11 litres = ₱115.909...
      expect(await perLitre(milk), 11590);
    });

    test('is the delivery price when the shelf was empty', () async {
      final Ingredient milk = await freshMilk();
      await deliver(milk, cartons: 10, total: const Money(115000));
      expect(await perLitre(milk), 11500);
    });

    test('does not count stock that has already been used', () async {
      // The old behaviour's failure, stated as a test. Six litres in at ₱125,
      // five of them used, then ten at ₱115. Averaging every purchase ever
      // would say ₱118.75; what is actually on the shelf says ₱115.91.
      final Ingredient milk = await freshMilk();
      await deliver(milk, cartons: 6, total: const Money(75000));
      await pos.stock.recordWaste(
        ingredientId: milk.id,
        quantity: Quantity.fromBase(5000, BaseUnit.millilitre),
        reason: WasteReason.spill,
      );
      await deliver(milk, cartons: 10, total: const Money(115000));

      expect(await perLitre(milk), 11590);
    });
  });

  group('what does not move the average', () {
    test('selling a coffee', () async {
      final Ingredient milk = await freshMilk(openingStock: 6000);
      await deliver(milk, cartons: 10, total: const Money(115000));
      final int before = await perLitre(milk);

      await pos.stock.recordWaste(
        ingredientId: milk.id,
        quantity: Quantity.fromBase(2000, BaseUnit.millilitre),
        reason: WasteReason.spill,
      );

      expect(await perLitre(milk), before);
      expect(
        await pos.stockOf(milk.id),
        Quantity.fromBase(14000, BaseUnit.millilitre),
      );
    });
  });

  group('a price typed in by hand', () {
    test('replaces the average rather than averaging into it', () async {
      final Ingredient milk = await freshMilk(openingStock: 6000);
      await deliver(milk, cartons: 10, total: const Money(115000));
      expect(await perLitre(milk), 11875);

      pos.clock.advance(const Duration(hours: 1));
      await pos.stock.recordCost(
        ingredientId: milk.id,
        cost: const UnitCost(13000, BaseUnit.millilitre),
        note: 'Supplier told me the new price',
      );

      expect(await perLitre(milk), 13000);
    });
  });

  group('history', () {
    test('a coffee sold yesterday keeps the cost it was sold at', () async {
      final Ingredient milk = await freshMilk(openingStock: 6000);
      final DateTime beforeTheSale = pos.clock.now();
      pos.clock.advance(const Duration(days: 1));

      await deliver(milk, cartons: 10, total: const Money(115000));

      final UnitCost? then = await CostingEngine(pos.db.db).costOfIngredient(
        milk.id,
        method: CostingMethod.weightedAverage,
        asOf: beforeTheSale,
      );
      expect(then!.centavosPer1000Base, 12500);
      expect(await perLitre(milk), 11875);
    });

    test('a delivery recorded late lands in the right place', () async {
      final Ingredient milk = await freshMilk(openingStock: 6000);
      await deliver(milk, cartons: 10, total: const Money(115000));

      // Rebuilding replays everything from the beginning, which is what makes
      // a late or out-of-order delivery come out the same on both tills.
      await pos.db.db.delete('ingredient_avg_cost');
      await const MovingAverageCost().rebuildAll(pos.db.db);

      expect(await perLitre(milk), 11875);
    });
  });

  group('the other setting', () {
    test('latest cost still answers what it costs to replace it', () async {
      final Ingredient milk = await freshMilk(openingStock: 6000);
      await deliver(milk, cartons: 10, total: const Money(115000));

      final UnitCost? latest = await CostingEngine(pos.db.db).costOfIngredient(
        milk.id,
        method: CostingMethod.latestCost,
        asOf: pos.clock.now(),
      );
      expect(latest!.centavosPer1000Base, 11500);
    });
  });
}
