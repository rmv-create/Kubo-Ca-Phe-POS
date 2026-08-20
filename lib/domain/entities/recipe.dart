import 'package:meta/meta.dart';

import '../../core/money/money.dart';
import '../../core/money/unit_cost.dart';
import '../../core/quantity/quantity.dart';
import 'ingredient.dart';

enum RecipeStatus {
  draft('draft', 'Draft'),
  active('active', 'In use'),
  retired('retired', 'Replaced');

  const RecipeStatus(this.code, this.label);

  final String code;
  final String label;

  static RecipeStatus fromCode(String code) => RecipeStatus.values.firstWhere(
    (RecipeStatus s) => s.code == code,
    orElse: () => RecipeStatus.draft,
  );
}

/// One ingredient in a recipe, and how much of it goes in.
@immutable
class RecipeLine {
  const RecipeLine({
    required this.id,
    required this.ingredientId,
    required this.ingredientName,
    required this.quantity,
    this.note,
    this.ingredient,
  });

  final int id;
  final int ingredientId;
  final String ingredientName;
  final Quantity quantity;
  final String? note;

  /// Attached when the caller needs the ingredient's cost as well.
  final Ingredient? ingredient;

  /// What this line costs at the ingredient's current price.
  Money? get cost {
    final Ingredient? source = ingredient;
    if (source?.currentCost == null) return null;
    return moneyFromMicroCentavos(
      source!.currentCost!.costMicroCentavos(quantity),
    );
  }
}

/// A recipe as it stood from one date to another.
///
/// Recipes are versioned rather than edited in place, so an order sold in
/// March keeps March's ingredients and March's cost even after the recipe
/// changes in June.
@immutable
class RecipeVersion {
  const RecipeVersion({
    required this.id,
    required this.recipeId,
    required this.versionNo,
    required this.effectiveFrom,
    required this.status,
    required this.lines,
    this.effectiveTo,
    this.note,
  });

  final int id;
  final int recipeId;
  final int versionNo;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final RecipeStatus status;
  final List<RecipeLine> lines;
  final String? note;

  bool get isCurrent => status == RecipeStatus.active && effectiveTo == null;

  /// Total cost, or null if any ingredient has no price yet — a partial cost
  /// would understate COGS and overstate profit.
  Money? get cost {
    if (lines.isEmpty) return null;
    int micro = 0;
    for (final RecipeLine line in lines) {
      final Ingredient? ingredient = line.ingredient;
      if (ingredient?.currentCost == null) return null;
      micro += ingredient!.currentCost!.costMicroCentavos(line.quantity);
    }
    return moneyFromMicroCentavos(micro);
  }

  /// Which ingredients are stopping this recipe from being costed.
  List<String> get ingredientsWithoutCost => <String>[
    for (final RecipeLine line in lines)
      if (line.ingredient?.currentCost == null) line.ingredientName,
  ];
}

/// One drink at one size, with its version history.
@immutable
class Recipe {
  const Recipe({
    required this.id,
    required this.productId,
    required this.productName,
    required this.sizeId,
    required this.sizeName,
    required this.sizeVolumeOz,
    required this.versions,
    this.notes,
  });

  final int id;
  final int productId;
  final String productName;
  final int sizeId;
  final String sizeName;
  final double sizeVolumeOz;
  final List<RecipeVersion> versions;
  final String? notes;

  RecipeVersion? get current {
    for (final RecipeVersion v in versions) {
      if (v.isCurrent) return v;
    }
    return null;
  }

  /// The version in force at [moment] — how a historical order is costed.
  RecipeVersion? versionAt(DateTime moment) {
    RecipeVersion? best;
    for (final RecipeVersion v in versions) {
      if (v.status == RecipeStatus.draft) continue;
      if (v.effectiveFrom.isAfter(moment)) continue;
      if (v.effectiveTo != null && !v.effectiveTo!.isAfter(moment)) continue;
      if (best == null || v.effectiveFrom.isAfter(best.effectiveFrom)) {
        best = v;
      }
    }
    return best;
  }

  bool get hasRecipe => current != null && current!.lines.isNotEmpty;

  String get title => '$sizeName $productName';
}

/// What one drink costs to make, and what that leaves.
@immutable
class DrinkCosting {
  const DrinkCosting({
    required this.recipeVersionId,
    required this.cost,
    required this.price,
    required this.consumption,
    required this.missingCosts,
  });

  /// Null when the drink has no recipe, which means it cannot be costed at all.
  final int? recipeVersionId;

  /// Null when the recipe exists but an ingredient has no price yet.
  final Money? cost;

  final Money price;

  /// How much of each ingredient this drink uses, recipe plus customisations.
  final Map<int, Quantity> consumption;

  /// Ingredient names that have no price, when [cost] is null.
  final List<String> missingCosts;

  bool get isCosted => cost != null;

  Money? get grossProfit => cost == null ? null : price - cost!;

  /// Gross margin in basis points (10000 = 100%), so it stays an integer.
  int? get grossMarginBasisPoints {
    final Money? profit = grossProfit;
    if (profit == null || price.isZero) return null;
    return (profit.centavos * 10000) ~/ price.centavos;
  }

  String? get marginLabel {
    final int? bp = grossMarginBasisPoints;
    return bp == null ? null : '${(bp / 100).toStringAsFixed(1)}%';
  }
}
