import 'package:sqflite_common/sqlite_api.dart';

import '../../../core/money/money.dart';
import '../../../core/money/unit_cost.dart';
import '../../../core/quantity/quantity.dart';
import '../../../core/time/clock.dart';
import '../../../domain/entities/ingredient.dart';
import '../../../domain/services/inventory_engine.dart';
import '../app_database.dart';
import 'pantry_seed.dart';

/// Writes [PantrySeed] — her ingredients, their costs, what she had on the
/// shelf and what goes into each drink — into a database that has none.
///
/// Like the menu seeder, it refuses to run if anything is already there: her
/// own ingredients and her own recipe edits must never be overwritten on a
/// later launch. It runs in one transaction, so either the whole pantry lands
/// or none of it does.
///
/// Recipes are written as version 1 of each drink, through the same tables
/// the recipe editor uses, so editing one afterwards starts version 2 and
/// everything already sold keeps the cost it was sold at.
class PantrySeeder {
  const PantrySeeder(this._db, this._clock);

  final AppDatabase _db;
  final Clock _clock;

  /// Returns true if it seeded, false if there was already a pantry.
  Future<bool> seedIfEmpty() async {
    final List<Map<String, Object?>> existing = await _db.db.rawQuery(
      'SELECT 1 FROM ingredients LIMIT 1',
    );
    if (existing.isNotEmpty) return false;

    await _db.transaction(_seed);
    return true;
  }

  Future<void> _seed(Transaction txn) async {
    final String now = _clock.nowIso();
    final String businessDate = now.substring(0, 10);

    final Map<String, int> ingredientIds = <String, int>{};
    final Map<String, Quantity> opening = <String, Quantity>{};

    for (final PantryItem item in PantrySeed.ingredients) {
      final Quantity perPurchase = Quantity.fromBase(
        item.perPurchase,
        item.unit,
      );
      final int id = await txn.insert('ingredients', <String, Object?>{
        'name': item.name,
        'category': item.category,
        'base_unit': item.unit.code,
        // She buys by the pack, the carton, the piece — her own words, so the
        // purchase screen reads the way the receipt from the shop does.
        'purchase_unit_code': item.buyBy.toLowerCase().replaceAll(' ', '_'),
        'purchase_unit_label': item.buyBy,
        'purchase_unit_size_milli': perPurchase.milli,
        'is_inventory_tracked': item.tracked ? 1 : 0,
        'reorder_threshold_milli': Quantity.fromBase(
          item.reorderAt,
          item.unit,
        ).milli,
        'critical_threshold_milli': Quantity.fromBase(
          item.panicAt,
          item.unit,
        ).milli,
        'target_stock_milli': 0,
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
      ingredientIds[item.name] = id;

      await txn.insert('ingredient_cost_history', <String, Object?>{
        'ingredient_id': id,
        'unit_cost_centavos_per_1000_base': UnitCost.perPurchaseUnit(
          price: Money(item.pricePerPurchase),
          baseUnitsPerPurchaseUnit: item.perPurchase,
          unit: item.unit,
        ).centavosPer1000Base,
        'effective_from': now,
        'source': 'seed',
        'created_at': now,
      });

      if (item.onHand > 0) {
        opening[item.name] = Quantity.fromBase(item.onHand, item.unit);
      }
    }

    // What was on the shelf the day she wrote it down, posted through the
    // stock ledger rather than written straight into the balance — so the
    // first entry against every ingredient says where its stock came from.
    await const InventoryEngine().post(
      txn,
      <PendingMovement>[
        for (final MapEntry<String, Quantity> entry in opening.entries)
          PendingMovement(
            ingredientId: ingredientIds[entry.key]!,
            delta: entry.value,
            type: MovementType.correction,
            reason: 'Opening stock',
          ),
      ],
      at: now,
      businessDate: businessDate,
    );

    for (final PantryRecipe recipe in PantrySeed.recipes) {
      await _writeRecipe(txn, recipe, ingredientIds, now);
    }
  }

  Future<void> _writeRecipe(
    Transaction txn,
    PantryRecipe recipe,
    Map<String, int> ingredientIds,
    String now,
  ) async {
    final List<Map<String, Object?>> rows = await txn.rawQuery(
      '''
      SELECT ps.product_id AS product_id, ps.size_id AS size_id
      FROM product_sizes ps
      JOIN products p ON p.id = ps.product_id
      JOIN sizes s ON s.id = ps.size_id
      WHERE p.name = ? COLLATE NOCASE AND s.name = ? COLLATE NOCASE
      LIMIT 1
      ''',
      <Object?>[recipe.drink, recipe.size],
    );
    // A recipe for a drink that is not on the menu is left for her to attach
    // herself rather than conjuring the drink to hang it on.
    if (rows.isEmpty) return;

    final int recipeId = await txn.insert('recipes', <String, Object?>{
      'product_id': rows.first['product_id'],
      'size_id': rows.first['size_id'],
      'created_at': now,
      'updated_at': now,
    });
    final int versionId = await txn.insert('recipe_versions', <String, Object?>{
      'recipe_id': recipeId,
      'version_no': 1,
      'effective_from': now,
      'status': 'active',
      'note': 'From the setup worksheet',
      'created_at': now,
      'updated_at': now,
    });

    for (final MapEntry<String, double> line in recipe.lines.entries) {
      final int? ingredientId = ingredientIds[line.key];
      if (ingredientId == null || line.value <= 0) continue;
      final PantryItem item = PantrySeed.ingredients.firstWhere(
        (PantryItem i) => i.name == line.key,
      );
      await txn.insert('recipe_items', <String, Object?>{
        'recipe_version_id': versionId,
        'ingredient_id': ingredientId,
        'qty_milli': Quantity.fromBase(line.value, item.unit).milli,
        'created_at': now,
      });
    }
  }
}
