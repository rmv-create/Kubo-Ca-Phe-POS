import 'package:meta/meta.dart';

import '../../core/money/money.dart';
import '../../core/money/unit_cost.dart';
import '../../core/quantity/measurement_unit.dart';
import '../../core/quantity/quantity.dart';

/// How much of an ingredient is left, relative to the levels the owner set.
enum StockStatus {
  /// At or below the level she called critical.
  critical('Critical'),

  /// At or below the level she reorders at.
  low('Low'),

  ok('OK'),

  /// The ingredient is deliberately not counted — ice made fresh each day.
  untracked('Not tracked');

  const StockStatus(this.label);

  final String label;

  bool get needsAttention => this == critical || this == low;
}

@immutable
class Ingredient {
  const Ingredient({
    required this.id,
    required this.name,
    required this.baseUnit,
    required this.purchaseUnitCode,
    required this.purchaseUnitLabel,
    required this.purchaseUnitSize,
    required this.isInventoryTracked,
    required this.reorderThreshold,
    required this.criticalThreshold,
    required this.targetStock,
    required this.isActive,
    this.category,
    this.defaultSupplierId,
    this.notes,
    this.onHand,
    this.currentCost,
  });

  final int id;
  final String name;
  final BaseUnit baseUnit;

  /// What she buys it by — kg, L, a carton, a pack of 50.
  final String purchaseUnitCode;
  final String purchaseUnitLabel;

  /// How much one of those contains, in base units.
  final Quantity purchaseUnitSize;

  /// False for things made fresh daily. They are still costed; they are just
  /// not counted down.
  final bool isInventoryTracked;

  final Quantity reorderThreshold;
  final Quantity criticalThreshold;
  final Quantity targetStock;
  final bool isActive;
  final String? category;
  final int? defaultSupplierId;
  final String? notes;

  /// Current balance, when the caller asked for it.
  final Quantity? onHand;

  /// Cost in force today, when the caller asked for it.
  final UnitCost? currentCost;

  StockStatus get status {
    if (!isInventoryTracked) return StockStatus.untracked;
    final Quantity? stock = onHand;
    if (stock == null) return StockStatus.ok;
    if (!criticalThreshold.isZero && stock <= criticalThreshold) {
      return StockStatus.critical;
    }
    if (!reorderThreshold.isZero && stock <= reorderThreshold) {
      return StockStatus.low;
    }
    return StockStatus.ok;
  }

  /// What one purchase unit costs at the current price.
  Money? get purchasePrice {
    final UnitCost? cost = currentCost;
    if (cost == null) return null;
    return moneyFromMicroCentavos(cost.costMicroCentavos(purchaseUnitSize));
  }

  /// `3.2 cartons` — the balance in the unit she buys in, which is how she
  /// thinks about whether she needs more.
  String? get onHandInPurchaseUnits {
    final Quantity? stock = onHand;
    if (stock == null || purchaseUnitSize.isZero) return null;
    final double units = stock.milli / purchaseUnitSize.milli;
    final String trimmed = units
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'\.?0+$'), '');
    return '$trimmed $purchaseUnitLabel${units == 1 ? '' : 's'}';
  }

  Ingredient copyWith({
    String? name,
    String? category,
    BaseUnit? baseUnit,
    String? purchaseUnitCode,
    String? purchaseUnitLabel,
    Quantity? purchaseUnitSize,
    bool? isInventoryTracked,
    Quantity? reorderThreshold,
    Quantity? criticalThreshold,
    Quantity? targetStock,
    int? defaultSupplierId,
    bool clearSupplier = false,
    String? notes,
    bool? isActive,
    Quantity? onHand,
    UnitCost? currentCost,
  }) => Ingredient(
    id: id,
    name: name ?? this.name,
    category: category ?? this.category,
    baseUnit: baseUnit ?? this.baseUnit,
    purchaseUnitCode: purchaseUnitCode ?? this.purchaseUnitCode,
    purchaseUnitLabel: purchaseUnitLabel ?? this.purchaseUnitLabel,
    purchaseUnitSize: purchaseUnitSize ?? this.purchaseUnitSize,
    isInventoryTracked: isInventoryTracked ?? this.isInventoryTracked,
    reorderThreshold: reorderThreshold ?? this.reorderThreshold,
    criticalThreshold: criticalThreshold ?? this.criticalThreshold,
    targetStock: targetStock ?? this.targetStock,
    defaultSupplierId: clearSupplier
        ? null
        : (defaultSupplierId ?? this.defaultSupplierId),
    notes: notes ?? this.notes,
    isActive: isActive ?? this.isActive,
    onHand: onHand ?? this.onHand,
    currentCost: currentCost ?? this.currentCost,
  );
}

/// One price the business has paid, and from when.
@immutable
class IngredientCost {
  const IngredientCost({
    required this.id,
    required this.ingredientId,
    required this.cost,
    required this.effectiveFrom,
    required this.source,
    this.note,
  });

  final int id;
  final int ingredientId;
  final UnitCost cost;
  final DateTime effectiveFrom;

  /// `purchase`, `manual` or `seed` — where the number came from.
  final String source;

  final String? note;
}

enum MovementType {
  sale('sale', 'Sold'),
  purchase('purchase', 'Bought in'),
  waste('waste', 'Wasted'),
  adjustment('adjustment', 'Stock count'),
  correction('correction', 'Corrected'),
  refundReversal('refund_reversal', 'Put back after a refund'),
  voidReversal('void_reversal', 'Put back after a void');

  const MovementType(this.code, this.label);

  final String code;
  final String label;

  static MovementType fromCode(String code) => MovementType.values.firstWhere(
    (MovementType t) => t.code == code,
    orElse: () => MovementType.correction,
  );
}

/// One entry in the stock ledger. Nothing changes stock without one.
@immutable
class InventoryMovement {
  const InventoryMovement({
    required this.id,
    required this.at,
    required this.businessDate,
    required this.ingredientId,
    required this.ingredientName,
    required this.type,
    required this.delta,
    required this.before,
    required this.after,
    required this.value,
    this.reason,
    this.orderId,
    this.note,
  });

  final int id;
  final DateTime at;
  final String businessDate;
  final int ingredientId;
  final String ingredientName;
  final MovementType type;
  final Quantity delta;
  final Quantity before;
  final Quantity after;
  final Money value;
  final String? reason;
  final int? orderId;
  final String? note;
}

enum WasteReason {
  spill('spill', 'Spilled'),
  spoiled('spoiled', 'Spoiled'),
  expired('expired', 'Expired'),
  wrongPrep('wrong_prep', 'Made wrong'),
  damaged('damaged', 'Damaged'),
  other('other', 'Other');

  const WasteReason(this.code, this.label);

  final String code;
  final String label;

  static WasteReason fromCode(String code) => WasteReason.values.firstWhere(
    (WasteReason r) => r.code == code,
    orElse: () => WasteReason.other,
  );
}

@immutable
class WasteEntry {
  const WasteEntry({
    required this.id,
    required this.at,
    required this.businessDate,
    required this.ingredientId,
    required this.ingredientName,
    required this.quantity,
    required this.reason,
    required this.value,
    this.notes,
  });

  final int id;
  final DateTime at;
  final String businessDate;
  final int ingredientId;
  final String ingredientName;
  final Quantity quantity;
  final WasteReason reason;
  final Money value;
  final String? notes;
}

/// What a physical count found, before it is applied.
@immutable
class StockVariance {
  const StockVariance({
    required this.ingredient,
    required this.expected,
    required this.actual,
  });

  final Ingredient ingredient;
  final Quantity expected;
  final Quantity actual;

  Quantity get variance => actual - expected;
  bool get matches => variance.isZero;

  Money? valueOf(UnitCost? cost) => cost == null
      ? null
      : moneyFromMicroCentavos(cost.costMicroCentavos(variance));
}
