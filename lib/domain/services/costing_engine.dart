import 'package:sqflite_common/sqlite_api.dart';

import '../../core/money/money.dart';
import '../../core/money/unit_cost.dart';
import '../../core/quantity/measurement_unit.dart';
import '../../core/quantity/quantity.dart';
import '../entities/business_settings.dart';
import '../entities/order_draft.dart';

/// Works out what a drink costs to make.
///
/// Two rules matter more than the arithmetic:
///  * a partial cost is not a cost. If any ingredient has no price, the drink
///    reports as uncosted rather than reporting a number that understates COGS
///    and overstates profit;
///  * the sum is accumulated in micro-centavos and rounded **once**, so a
///    ten-ingredient recipe rounds at the end rather than ten times along the
///    way.
class CostingEngine {
  const CostingEngine(this._db);

  final DatabaseExecutor _db;

  /// Costs one drink as configured, including what its options add or remove.
  Future<DrinkCost> costOf(
    DraftItem item, {
    required CostingMethod method,
    required DateTime asOf,
  }) => costConfiguration(
    productId: item.product.id,
    sizeId: item.size.size.id,
    optionIds: item.options.map((DraftOption o) => o.option.id).toList(),
    price: item.unitPrice,
    method: method,
    asOf: asOf,
  );

  Future<DrinkCost> costConfiguration({
    required int productId,
    required int sizeId,
    required List<int> optionIds,
    required Money price,
    required CostingMethod method,
    required DateTime asOf,
  }) async {
    final int? versionId = await recipeVersionFor(
      productId: productId,
      sizeId: sizeId,
      asOf: asOf,
    );
    if (versionId == null) {
      return DrinkCost.noRecipe(price: price);
    }

    final Map<int, Quantity> consumption = await consumptionFor(
      recipeVersionId: versionId,
      optionIds: optionIds,
    );
    if (consumption.isEmpty) {
      return DrinkCost.noRecipe(price: price, recipeVersionId: versionId);
    }

    int micro = 0;
    final List<String> missing = <String>[];
    for (final MapEntry<int, Quantity> entry in consumption.entries) {
      final UnitCost? cost = await costOfIngredient(
        entry.key,
        method: method,
        asOf: asOf,
      );
      if (cost == null) {
        missing.add(await _ingredientName(entry.key));
        continue;
      }
      micro += cost.costMicroCentavos(entry.value);
    }

    if (missing.isNotEmpty) {
      return DrinkCost(
        recipeVersionId: versionId,
        cost: null,
        price: price,
        consumption: consumption,
        ingredientsWithoutCost: missing,
      );
    }

    return DrinkCost(
      recipeVersionId: versionId,
      cost: moneyFromMicroCentavos(micro),
      price: price,
      consumption: consumption,
      ingredientsWithoutCost: const <String>[],
    );
  }

  /// The recipe version in force at [asOf] for one product and size.
  ///
  /// Historical orders resolve against the version that was live when they
  /// were sold, which is what stops a recipe edit today from rewriting last
  /// month's margins.
  Future<int?> recipeVersionFor({
    required int productId,
    required int sizeId,
    required DateTime asOf,
  }) async {
    final String at = asOf.toUtc().toIso8601String();
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      '''
      SELECT rv.id AS id
      FROM recipes r
      JOIN recipe_versions rv ON rv.recipe_id = r.id
      WHERE r.product_id = ? AND r.size_id = ?
        AND rv.status <> 'draft'
        AND rv.effective_from <= ?
        AND (rv.effective_to IS NULL OR rv.effective_to > ?)
      ORDER BY rv.effective_from DESC, rv.version_no DESC
      LIMIT 1
      ''',
      <Object?>[productId, sizeId, at, at],
    );
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  /// Recipe amounts plus what the chosen options add or take away.
  ///
  /// An option's effect can be negative — "No Sugar" removing syrup the base
  /// recipe includes — so a total is clamped at zero rather than going below.
  Future<Map<int, Quantity>> consumptionFor({
    required int recipeVersionId,
    required List<int> optionIds,
  }) async {
    final Map<int, Quantity> totals = <int, Quantity>{};

    final List<Map<String, Object?>> recipeRows = await _db.rawQuery(
      'SELECT ri.ingredient_id AS id, ri.qty_milli AS qty, '
      'i.base_unit AS unit '
      'FROM recipe_items ri '
      'JOIN ingredients i ON i.id = ri.ingredient_id '
      'WHERE ri.recipe_version_id = ?',
      <Object?>[recipeVersionId],
    );
    for (final Map<String, Object?> row in recipeRows) {
      final int id = row['id']! as int;
      totals[id] = Quantity(
        row['qty']! as int,
        BaseUnit.fromCode(row['unit']! as String),
      );
    }

    if (optionIds.isNotEmpty) {
      final String placeholders = List<String>.filled(
        optionIds.length,
        '?',
      ).join(',');
      final List<Map<String, Object?>> effects = await _db.rawQuery(
        'SELECT e.ingredient_id AS id, e.qty_milli_delta AS delta, '
        'i.base_unit AS unit '
        'FROM option_ingredient_effects e '
        'JOIN ingredients i ON i.id = e.ingredient_id '
        'WHERE e.option_id IN ($placeholders)',
        optionIds,
      );
      for (final Map<String, Object?> row in effects) {
        final int id = row['id']! as int;
        final BaseUnit unit = BaseUnit.fromCode(row['unit']! as String);
        final Quantity delta = Quantity(row['delta']! as int, unit);
        final Quantity next = (totals[id] ?? Quantity.zero(unit)) + delta;
        totals[id] = next.isNegative ? Quantity.zero(unit) : next;
      }
    }

    totals.removeWhere((int _, Quantity q) => q.isZero);
    return totals;
  }

  /// The cost of one ingredient under the configured method.
  ///
  /// `latest` takes the most recent price effective on or before [asOf];
  /// `weighted average` averages every price recorded up to then, weighted by
  /// the quantity actually bought at each.
  Future<UnitCost?> costOfIngredient(
    int ingredientId, {
    required CostingMethod method,
    required DateTime asOf,
  }) async {
    final String at = asOf.toUtc().toIso8601String();
    final List<Map<String, Object?>> unitRow = await _db.query(
      'ingredients',
      columns: <String>['base_unit'],
      where: 'id = ?',
      whereArgs: <Object?>[ingredientId],
      limit: 1,
    );
    if (unitRow.isEmpty) return null;
    final BaseUnit unit = BaseUnit.fromCode(
      unitRow.first['base_unit']! as String,
    );

    if (method == CostingMethod.weightedAverage) {
      final List<Map<String, Object?>> rows = await _db.rawQuery(
        '''
        SELECT SUM(pi.total_cost_centavos) AS spend,
               SUM(pi.qty_milli) AS qty
        FROM purchase_items pi
        JOIN purchases p ON p.id = pi.purchase_id
        WHERE pi.ingredient_id = ? AND p.purchased_at <= ?
        ''',
        <Object?>[ingredientId, at],
      );
      final int? spend = rows.first['spend'] as int?;
      final int? qty = rows.first['qty'] as int?;
      if (spend != null && qty != null && qty > 0) {
        // spend is centavos for `qty` milli-base-units; scale to per 1000 base.
        return UnitCost((spend * 1000000) ~/ qty, unit);
      }
      // No purchases yet — fall back rather than reporting no cost at all.
    }

    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'SELECT unit_cost_centavos_per_1000_base AS cost '
      'FROM ingredient_cost_history '
      'WHERE ingredient_id = ? AND effective_from <= ? '
      'ORDER BY effective_from DESC, id DESC LIMIT 1',
      <Object?>[ingredientId, at],
    );
    if (rows.isEmpty) return null;
    return UnitCost(rows.first['cost']! as int, unit);
  }

  Future<String> _ingredientName(int id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'ingredients',
      columns: <String>['name'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? 'Ingredient $id' : rows.first['name']! as String;
  }
}

/// The result of costing one drink.
class DrinkCost {
  const DrinkCost({
    required this.recipeVersionId,
    required this.cost,
    required this.price,
    required this.consumption,
    required this.ingredientsWithoutCost,
  });

  /// No recipe at all: nothing is consumed and nothing can be costed.
  factory DrinkCost.noRecipe({required Money price, int? recipeVersionId}) =>
      DrinkCost(
        recipeVersionId: recipeVersionId,
        cost: null,
        price: price,
        consumption: const <int, Quantity>{},
        ingredientsWithoutCost: const <String>[],
      );

  final int? recipeVersionId;
  final Money? cost;
  final Money price;
  final Map<int, Quantity> consumption;
  final List<String> ingredientsWithoutCost;

  bool get isCosted => cost != null;

  Money? get grossProfit => cost == null ? null : price - cost!;

  /// Basis points, so margin stays an integer: 3525 is 35.25%.
  int? get grossMarginBasisPoints {
    final Money? profit = grossProfit;
    if (profit == null || price.isZero) return null;
    return (profit.centavos * 10000) ~/ price.centavos;
  }

  String get reasonUncosted {
    if (isCosted) return '';
    if (recipeVersionId == null) return 'No recipe yet';
    if (ingredientsWithoutCost.isNotEmpty) {
      return 'No price for ${ingredientsWithoutCost.join(', ')}';
    }
    return 'Recipe is empty';
  }
}
