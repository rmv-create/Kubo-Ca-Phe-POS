import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';

void main() {
  group('Quantity', () {
    test('holds thousandths of a base unit exactly', () {
      expect(Quantity.fromBase(18.5, BaseUnit.gram).milli, 18500);
      expect(Quantity.fromBase(0.001, BaseUnit.gram).milli, 1);
      expect(Quantity.fromBase(240, BaseUnit.millilitre).milli, 240000);
      expect(Quantity.fromBase(1, BaseUnit.piece).milli, 1000);
    });

    test('converts from purchase units', () {
      final Quantity oneKilo = Quantity.fromPurchaseUnits(
        1,
        baseUnit: BaseUnit.gram,
        baseUnitsPerPurchaseUnit: 1000,
      );
      expect(oneKilo.inBaseUnits, 1000);

      final Quantity oneLitre = Quantity.fromPurchaseUnits(
        1,
        baseUnit: BaseUnit.millilitre,
        baseUnitsPerPurchaseUnit: 1000,
      );
      expect(oneLitre.inBaseUnits, 1000);

      // A carton whose size only the owner knows: 946 ml.
      final Quantity carton = Quantity.fromPurchaseUnits(
        2,
        baseUnit: BaseUnit.millilitre,
        baseUnitsPerPurchaseUnit: 946,
      );
      expect(carton.inBaseUnits, 1892);
    });

    test('adds and subtracts without drift', () {
      Quantity stock = Quantity.fromBase(1000, BaseUnit.millilitre);
      for (int i = 0; i < 100; i++) {
        stock = stock - Quantity.fromBase(2.5, BaseUnit.millilitre);
      }
      expect(stock, Quantity.fromBase(750, BaseUnit.millilitre));
      expect(stock.milli, 750000);
    });

    test('refuses to mix incompatible units', () {
      final Quantity grams = Quantity.fromBase(10, BaseUnit.gram);
      final Quantity millilitres = Quantity.fromBase(10, BaseUnit.millilitre);
      expect(() => grams + millilitres, throwsArgumentError);
      expect(() => grams > millilitres, throwsArgumentError);
    });

    test('goes negative, so an oversell is visible rather than clamped', () {
      final Quantity result =
          Quantity.fromBase(1, BaseUnit.piece) -
          Quantity.fromBase(3, BaseUnit.piece);
      expect(result.isNegative, isTrue);
      expect(result.inBaseUnits, -2);
    });

    test('reads in the unit a person would use', () {
      expect(Quantity.fromBase(18.5, BaseUnit.gram).format(), '18.5 g');
      expect(Quantity.fromBase(1500, BaseUnit.gram).format(), '1.5 kg');
      expect(Quantity.fromBase(240, BaseUnit.millilitre).format(), '240 ml');
      expect(Quantity.fromBase(2000, BaseUnit.millilitre).format(), '2 L');
      expect(Quantity.fromBase(30, BaseUnit.piece).format(), '30 pcs');
    });
  });

  group('PurchaseUnit', () {
    test('knows how many base units each standard unit holds', () {
      expect(PurchaseUnit.kilogram.baseUnitsPerUnit, 1000);
      expect(PurchaseUnit.litre.baseUnitsPerUnit, 1000);
      expect(PurchaseUnit.piece.baseUnitsPerUnit, 1);
    });

    test('does not pretend to know how big a carton is', () {
      // Carton, bottle and pack sizes are per-ingredient business data the
      // owner supplies; they are deliberately absent from the standard list.
      expect(PurchaseUnit.tryFromCode('carton'), isNull);
      expect(PurchaseUnit.tryFromCode('bottle'), isNull);
      expect(PurchaseUnit.tryFromCode('pack'), isNull);
    });
  });
}
