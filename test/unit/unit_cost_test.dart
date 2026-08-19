import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/money/unit_cost.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';

void main() {
  group('UnitCost', () {
    test('scales a purchase price to a per-1000-base cost', () {
      // SAMPLE figures, not the business's real prices.
      final UnitCost beans = UnitCost.perPurchaseUnit(
        price: Money.of(1200),
        baseUnitsPerPurchaseUnit: 1000, // 1 kg
        unit: BaseUnit.gram,
      );
      expect(beans.centavosPer1000Base, 120000);

      final UnitCost milk = UnitCost.perPurchaseUnit(
        price: Money.of(90),
        baseUnitsPerPurchaseUnit: 1000, // 1 L
        unit: BaseUnit.millilitre,
      );
      expect(milk.centavosPer1000Base, 9000);
    });

    test('keeps cheap-per-unit ingredients representable', () {
      // ₱90/L is ₱0.09 per ml — unrepresentable in whole centavos per ml,
      // but exact as centavos per litre.
      const UnitCost milk = UnitCost(9000, BaseUnit.millilitre);
      final Quantity used = Quantity.fromBase(240, BaseUnit.millilitre);
      expect(
        moneyFromMicroCentavos(milk.costMicroCentavos(used)),
        Money.of(21, 60),
      );
    });

    test('handles a purchase unit whose size is not a round number', () {
      // SAMPLE: a 946 ml carton at ₱185.
      final UnitCost oat = UnitCost.perPurchaseUnit(
        price: Money.of(185),
        baseUnitsPerPurchaseUnit: 946,
        unit: BaseUnit.millilitre,
      );
      // ₱185 / 0.946 L ≈ ₱195.56 per litre
      expect(oat.centavosPer1000Base, 19556);
    });

    test('refuses to cost a quantity in the wrong dimension', () {
      const UnitCost beans = UnitCost(120000, BaseUnit.gram);
      expect(
        () => beans.costMicroCentavos(
          Quantity.fromBase(240, BaseUnit.millilitre),
        ),
        throwsArgumentError,
      );
    });
  });

  group('rounding to centavos', () {
    test('rounds half away from zero', () {
      expect(moneyFromMicroCentavos(1500000), const Money(2));
      expect(moneyFromMicroCentavos(2500000), const Money(3));
      expect(moneyFromMicroCentavos(-1500000), const Money(-2));
      expect(moneyFromMicroCentavos(1499999), const Money(1));
    });

    test('rounds once for the whole recipe, not per ingredient', () {
      // Three ingredients that each land on a third of a centavo. Rounding
      // each one separately would give ₱0.00; rounding the sum gives ₱0.01.
      const int third = 333334;
      final int perIngredient = moneyFromMicroCentavos(third).centavos * 3;
      final int summedFirst = moneyFromMicroCentavos(third * 3).centavos;
      expect(perIngredient, 0);
      expect(summedFirst, 1);
    });

    test('a refund reverses a charge exactly', () {
      const int cost = 2160000; // ₱21.60 worth of micro-centavos
      expect(
        moneyFromMicroCentavos(cost) + moneyFromMicroCentavos(-cost),
        Money.zero,
      );
    });
  });
}
