import 'package:meta/meta.dart';

/// The three physical dimensions this business measures in.
///
/// Every ingredient is stored internally in exactly one of these base units,
/// so recipes, inventory and costing never have to guess what a number means.
enum BaseUnit {
  /// Mass, base unit gram.
  gram('g', 'Grams'),

  /// Volume, base unit millilitre.
  millilitre('ml', 'Millilitres'),

  /// Discrete count, base unit piece.
  piece('pcs', 'Pieces');

  const BaseUnit(this.code, this.label);

  final String code;
  final String label;

  static BaseUnit fromCode(String code) => BaseUnit.values.firstWhere(
    (BaseUnit u) => u.code == code,
    orElse: () => throw ArgumentError('Unknown base unit: $code'),
  );
}

/// A unit the owner actually buys or types in, expressed as a multiple of its
/// [BaseUnit]. Purchase units that are business-specific (a *carton* of oat
/// milk, a *pack* of cups) carry their size on the ingredient record instead,
/// because only the owner knows how big her cartons are.
@immutable
class PurchaseUnit {
  const PurchaseUnit({
    required this.code,
    required this.label,
    required this.baseUnit,
    required this.baseUnitsPerUnit,
  });

  final String code;
  final String label;
  final BaseUnit baseUnit;

  /// How many base units one of these contains, e.g. 1 kg = 1000 g.
  final double baseUnitsPerUnit;

  static const PurchaseUnit gram = PurchaseUnit(
    code: 'g',
    label: 'Gram',
    baseUnit: BaseUnit.gram,
    baseUnitsPerUnit: 1,
  );
  static const PurchaseUnit kilogram = PurchaseUnit(
    code: 'kg',
    label: 'Kilogram',
    baseUnit: BaseUnit.gram,
    baseUnitsPerUnit: 1000,
  );
  static const PurchaseUnit millilitre = PurchaseUnit(
    code: 'ml',
    label: 'Millilitre',
    baseUnit: BaseUnit.millilitre,
    baseUnitsPerUnit: 1,
  );
  static const PurchaseUnit litre = PurchaseUnit(
    code: 'L',
    label: 'Litre',
    baseUnit: BaseUnit.millilitre,
    baseUnitsPerUnit: 1000,
  );
  static const PurchaseUnit piece = PurchaseUnit(
    code: 'pcs',
    label: 'Piece',
    baseUnit: BaseUnit.piece,
    baseUnitsPerUnit: 1,
  );

  /// Units whose size is fixed by physics. Cartons, bottles and packs are not
  /// here on purpose — their size is configured per ingredient.
  static const List<PurchaseUnit> standard = <PurchaseUnit>[
    gram,
    kilogram,
    millilitre,
    litre,
    piece,
  ];

  static PurchaseUnit? tryFromCode(String code) {
    for (final PurchaseUnit u in standard) {
      if (u.code == code) return u;
    }
    return null;
  }
}
