import 'package:meta/meta.dart';

import 'measurement_unit.dart';

/// An amount of an ingredient, held as an exact integer count of
/// **milli-base-units** (thousandths of a gram, millilitre or piece).
///
/// 18.5 g of coffee is `Quantity(18500, BaseUnit.gram)`. Recipes rarely need
/// more precision than 0.001 g, and integers keep inventory balances from
/// drifting over thousands of deductions.
@immutable
class Quantity implements Comparable<Quantity> {
  const Quantity(this.milli, this.unit);

  const Quantity.zero(this.unit) : milli = 0;

  /// Builds from a human-entered amount in base units, e.g. `18.5` grams.
  factory Quantity.fromBase(double baseUnits, BaseUnit unit) =>
      Quantity((baseUnits * 1000).round(), unit);

  /// Builds from an amount expressed in a purchase unit, e.g. 1.5 kg.
  factory Quantity.fromPurchaseUnits(
    double amount, {
    required BaseUnit baseUnit,
    required double baseUnitsPerPurchaseUnit,
  }) => Quantity((amount * baseUnitsPerPurchaseUnit * 1000).round(), baseUnit);

  /// Exact amount in thousandths of a base unit. This is what SQLite stores.
  final int milli;
  final BaseUnit unit;

  double get inBaseUnits => milli / 1000;

  bool get isZero => milli == 0;
  bool get isNegative => milli < 0;
  bool get isPositive => milli > 0;

  Quantity operator +(Quantity other) {
    _assertSameUnit(other);
    return Quantity(milli + other.milli, unit);
  }

  Quantity operator -(Quantity other) {
    _assertSameUnit(other);
    return Quantity(milli - other.milli, unit);
  }

  Quantity operator -() => Quantity(-milli, unit);

  Quantity operator *(int multiplier) => Quantity(milli * multiplier, unit);

  Quantity get abs => Quantity(milli.abs(), unit);

  bool operator >(Quantity other) {
    _assertSameUnit(other);
    return milli > other.milli;
  }

  bool operator >=(Quantity other) {
    _assertSameUnit(other);
    return milli >= other.milli;
  }

  bool operator <(Quantity other) {
    _assertSameUnit(other);
    return milli < other.milli;
  }

  bool operator <=(Quantity other) {
    _assertSameUnit(other);
    return milli <= other.milli;
  }

  void _assertSameUnit(Quantity other) {
    if (other.unit != unit) {
      throw ArgumentError(
        'Cannot combine ${unit.code} with ${other.unit.code}: '
        'ingredients must share a base unit.',
      );
    }
  }

  /// Display in the most readable unit: 1500 g reads as `1.5 kg`.
  String format({bool preferLargeUnit = true}) {
    final double base = inBaseUnits;
    if (preferLargeUnit && unit == BaseUnit.gram && base.abs() >= 1000) {
      return '${_trim(base / 1000)} kg';
    }
    if (preferLargeUnit && unit == BaseUnit.millilitre && base.abs() >= 1000) {
      return '${_trim(base / 1000)} L';
    }
    return '${_trim(base)} ${unit.code}';
  }

  static String _trim(double value) {
    final String fixed = value.toStringAsFixed(3);
    if (!fixed.contains('.')) return fixed;
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  @override
  int compareTo(Quantity other) {
    _assertSameUnit(other);
    return milli.compareTo(other.milli);
  }

  @override
  bool operator ==(Object other) =>
      other is Quantity && other.milli == milli && other.unit == unit;

  @override
  int get hashCode => Object.hash(milli, unit);

  @override
  String toString() => format();
}
