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
  CostingEngine(this._db);

  final DatabaseExecutor _db;

  /// What has already been looked up, for the life of this engine — which is
  /// one order, one void, one refund.
  ///
  /// A two-drink order asks for the same milk, the same cup and the same
  /// straw several times over: once to cost the line, once more to value the
  /// stock it takes off the shelf. On a phone's browser every one of those
  /// questions is a separate errand to the database, and the errands are what
  /// she feels as waiting. Asking once and remembering the answer took a
  /// two-drink order from 184 errands to a couple of dozen.
  ///
  /// It is only ever a cache of what the database said at one
  /// instant in time, so it cannot drift: a new order builds a new engine.
  final Map<String, _Priced> _priced = <String, _Priced>{};
  final Map<String, int?> _versions = <String, int?>{};

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
      productId: productId,
      sizeId: sizeId,
    );
    if (consumption.isEmpty) {
      return DrinkCost.noRecipe(price: price, recipeVersionId: versionId);
    }

    // Everything this drink uses, priced in one question.
    await _prime(consumption.keys, asOf: asOf);

    int micro = 0;
    final List<String> missing = <String>[];
    for (final MapEntry<int, Quantity> entry in consumption.entries) {
      final UnitCost? cost = await costOfIngredient(
        entry.key,
        method: method,
        asOf: asOf,
      );
      if (cost == null) {
        missing.add(await _ingredientName(entry.key, asOf: asOf));
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
    final String key = '$at|$productId|$sizeId';
    if (_versions.containsKey(key)) return _versions[key];
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
    return _versions[key] = rows.isEmpty ? null : rows.first['id'] as int?;
  }

  /// Recipe amounts plus what the chosen options add or take away.
  ///
  /// An option's effect can be negative — "No Sugar" removing syrup the base
  /// recipe includes — so a total is clamped at zero rather than going below.
  Future<Map<int, Quantity>> consumptionFor({
    required int recipeVersionId,
    required List<int> optionIds,
    int? productId,
    int? sizeId,
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
      // An effect with no product is a rule for every drink; one that names
      // a product and a size applies only there. A rule for another drink is
      // simply not this drink's business.
      final List<Map<String, Object?>> effects = await _db.rawQuery(
        'SELECT e.ingredient_id AS id, e.qty_milli_delta AS delta, '
        'i.base_unit AS unit '
        'FROM option_ingredient_effects e '
        'JOIN ingredients i ON i.id = e.ingredient_id '
        'WHERE e.option_id IN ($placeholders) '
        'AND (e.product_id IS NULL OR e.product_id = ?) '
        'AND (e.size_id IS NULL OR e.size_id = ?)',
        <Object?>[...optionIds, productId, sizeId],
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
  /// `latest` takes the most recent price effective on or before [asOf] —
  /// what it would cost to replace what the drink used.
  ///
  /// `weighted average` takes what the stock on the shelf actually cost on
  /// that day: a moving average, so six litres at ₱125 with ten more at ₱115
  /// is ₱118.75, and the milk already drunk is not in it. See
  /// [MovingAverageCost].
  Future<UnitCost?> costOfIngredient(
    int ingredientId, {
    required CostingMethod method,
    required DateTime asOf,
  }) async {
    final _Priced? priced = await _priceOf(ingredientId, asOf: asOf);
    if (priced == null) return null;
    return priced.under(method);
  }

  /// Reads the unit, the shelf cost and the latest price for many ingredients
  /// at once, and remembers them.
  ///
  /// One question for a whole recipe rather than three for every ingredient
  /// in it. The two inner selects are each the same "most recent on or before
  /// this moment" the single-ingredient version asked for, so the answers are
  /// identical — there are simply far fewer errands.
  Future<void> _prime(Iterable<int> ids, {required DateTime asOf}) async {
    final String at = asOf.toUtc().toIso8601String();
    final List<int> wanted = <int>[
      for (final int id in ids)
        if (!_priced.containsKey('$at|$id')) id,
    ];
    if (wanted.isEmpty) return;

    final String holes = List<String>.filled(wanted.length, '?').join(',');
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      '''
      SELECT i.id        AS id,
             i.base_unit AS unit,
             i.name      AS name,
             (SELECT ch.unit_cost_centavos_per_1000_base
                FROM ingredient_cost_history ch
               WHERE ch.ingredient_id = i.id AND ch.effective_from <= ?
               ORDER BY ch.effective_from DESC, ch.id DESC
               LIMIT 1)  AS latest,
             (SELECT a.avg_after_centavos_per_1000_base
                FROM ingredient_avg_cost a
               WHERE a.ingredient_id = i.id AND a.effective_from <= ?
               ORDER BY a.effective_from DESC, a.id DESC
               LIMIT 1)  AS average
      FROM ingredients i
      WHERE i.id IN ($holes)
      ''',
      <Object?>[at, at, ...wanted],
    );

    for (final Map<String, Object?> row in rows) {
      final int id = row['id']! as int;
      _priced['$at|$id'] = _Priced(
        unit: BaseUnit.fromCode(row['unit']! as String),
        name: row['name']! as String,
        latest: row['latest'] as int?,
        average: row['average'] as int?,
      );
    }
    // An ingredient that is not there at all is remembered as absent, so a
    // second ask does not go looking for it again.
    for (final int id in wanted) {
      _priced.putIfAbsent('$at|$id', () => const _Priced.missing());
    }
  }

  Future<_Priced?> _priceOf(int id, {required DateTime asOf}) async {
    final String key = '${asOf.toUtc().toIso8601String()}|$id';
    if (!_priced.containsKey(key)) await _prime(<int>[id], asOf: asOf);
    final _Priced? priced = _priced[key];
    return priced == null || priced.isMissing ? null : priced;
  }

  Future<String> _ingredientName(int id, {required DateTime asOf}) async {
    final _Priced? priced = await _priceOf(id, asOf: asOf);
    return priced?.name ?? 'Ingredient $id';
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

/// What one ingredient costs, as the database had it at one instant.
class _Priced {
  const _Priced({
    required this.unit,
    required this.name,
    required this.latest,
    required this.average,
  });

  const _Priced.missing()
    : unit = BaseUnit.gram,
      name = '',
      latest = null,
      average = null;

  final BaseUnit unit;
  final String name;

  /// The most recent price on or before the moment asked about.
  final int? latest;

  /// What the stock on the shelf cost on that day, if it is known.
  final int? average;

  bool get isMissing => name.isEmpty;

  UnitCost? under(CostingMethod method) {
    final int? chosen = method == CostingMethod.weightedAverage
        ? (average ?? latest)
        : latest;
    return chosen == null ? null : UnitCost(chosen, unit);
  }
}
