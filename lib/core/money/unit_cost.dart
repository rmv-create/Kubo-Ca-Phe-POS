import 'package:meta/meta.dart';

import '../quantity/measurement_unit.dart';
import '../quantity/quantity.dart';
import 'money.dart';

/// The cost of an ingredient, held as an exact integer number of **centavos
/// per 1000 base units** — i.e. centavos per kilogram, per litre, or per 1000
/// pieces.
///
/// Storing "per 1000" rather than "per unit" is what makes integer costing
/// possible: milk at ₱90 per litre is ₱0.09 per millilitre, which rounds to
/// nothing in centavos, but is exactly `9000` centavos per litre here.
@immutable
class UnitCost implements Comparable<UnitCost> {
  const UnitCost(this.centavosPer1000Base, this.unit);

  const UnitCost.zero(this.unit) : centavosPer1000Base = 0;

  /// e.g. coffee bought at ₱1,200.00 per kilogram.
  factory UnitCost.perPurchaseUnit({
    required Money price,
    required double baseUnitsPerPurchaseUnit,
    required BaseUnit unit,
  }) {
    if (baseUnitsPerPurchaseUnit <= 0) {
      throw ArgumentError('A purchase unit must contain a positive amount.');
    }
    // price is for `baseUnitsPerPurchaseUnit` base units;
    // scale it to exactly 1000 base units.
    final double per1000 = price.centavos * 1000 / baseUnitsPerPurchaseUnit;
    return UnitCost(per1000.round(), unit);
  }

  final int centavosPer1000Base;
  final BaseUnit unit;

  bool get isZero => centavosPer1000Base == 0;

  /// The cost of [quantity] of this ingredient, in **micro-centavos**
  /// (millionths of a centavo). Intermediate costs stay at this precision so
  /// that a recipe of ten small ingredients rounds exactly once, at the end,
  /// rather than ten times along the way.
  int costMicroCentavos(Quantity quantity) {
    if (quantity.unit != unit) {
      throw ArgumentError(
        'Cost is per ${unit.code} but quantity is in ${quantity.unit.code}.',
      );
    }
    return quantity.milli * centavosPer1000Base;
  }

  /// Display form: `₱1,200.00 / kg`.
  String format() {
    final String per = switch (unit) {
      BaseUnit.gram => 'kg',
      BaseUnit.millilitre => 'L',
      BaseUnit.piece => '1000 pcs',
    };
    return '${Money(centavosPer1000Base).format()} / $per';
  }

  @override
  int compareTo(UnitCost other) =>
      centavosPer1000Base.compareTo(other.centavosPer1000Base);

  @override
  bool operator ==(Object other) =>
      other is UnitCost &&
      other.centavosPer1000Base == centavosPer1000Base &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(centavosPer1000Base, unit);

  @override
  String toString() => format();
}

/// Converts an accumulated micro-centavo cost into a real, storable amount.
///
/// Rounds half away from zero, which is what a person doing the arithmetic on
/// paper would do, and is symmetric for refunds and reversals.
Money moneyFromMicroCentavos(int microCentavos) {
  const int scale = 1000000;
  final int magnitude = microCentavos.abs();
  final int rounded = (magnitude + scale ~/ 2) ~/ scale;
  return Money(microCentavos.isNegative ? -rounded : rounded);
}
