import 'package:sqflite_common/sqlite_api.dart';

import '../../../core/money/money.dart';
import '../../../core/money/unit_cost.dart';
import '../../../core/quantity/measurement_unit.dart';
import '../../../core/quantity/quantity.dart';
import '../../../core/time/clock.dart';
import '../../../domain/entities/business_settings.dart';
import '../../../domain/entities/ingredient.dart';
import '../../../domain/services/inventory_engine.dart';
import '../../../domain/services/moving_average_cost.dart';
import '../app_database.dart';
import 'option_effects_seed.dart';
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
///
/// When she sends a corrected sheet, [seedVersion] goes up and the recipes
/// she has not touched are rewritten in place on the next launch. One she
/// *has* edited is left exactly as she left it: the app does not overrule
/// her own work with a file she sent before she changed her mind.
class PantrySeeder {
  const PantrySeeder(this._db, this._clock);

  final AppDatabase _db;
  final Clock _clock;

  /// Which edition of the worksheet is in [PantrySeed].
  ///
  /// 1 — the first setup workbook.
  /// 2 — the corrected recipe sheet of 7 November, which moved the sea salt
  ///     cream from Ca Phe Sua Da to Ca Phe Muoi, where it belongs.
  /// 3 — what each customisation takes out of stock, so a customised drink
  ///     is costed as the drink she actually made.
  static const int seedVersion = 3;

  /// The note every recipe written from the worksheet carries. A recipe
  /// without it is one she wrote, and is never touched.
  static const String _fromWorksheet = 'From the setup worksheet';

  /// Returns true if it wrote anything.
  Future<bool> seedIfEmpty() async {
    final List<Map<String, Object?>> existing = await _db.db.rawQuery(
      'SELECT 1 FROM ingredients LIMIT 1',
    );
    if (existing.isEmpty) {
      await _db.transaction(_seed);
      await _stampVersion();
      return true;
    }

    if (await _storedVersion() >= seedVersion) return false;
    await _db.transaction((Transaction txn) async {
      await _refreshRecipes(txn);
      await _writeOptionEffects(txn);
    });
    await _stampVersion();
    return true;
  }

  Future<int> _storedVersion() async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'app_settings',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[SettingKeys.pantrySeedVersion],
      limit: 1,
    );
    if (rows.isEmpty) return 1;
    return int.tryParse(rows.first['value'] as String? ?? '') ?? 1;
  }

  Future<void> _stampVersion() =>
      _db.db.insert('app_settings', <String, Object?>{
        'key': SettingKeys.pantrySeedVersion,
        'value': '$seedVersion',
        'updated_at': _clock.nowIso(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Rewrites the worksheet recipes she has not edited.
  ///
  /// In place, on the version that is already live: these recipes have no
  /// history worth keeping — they were a transcription of a sheet that turned
  /// out to be wrong — and anything already sold carries its own cost on the
  /// order line regardless.
  Future<void> _refreshRecipes(Transaction txn) async {
    final String now = _clock.nowIso();
    final Map<String, int> ingredientIds = <String, int>{
      for (final Map<String, Object?> row in await txn.query(
        'ingredients',
        columns: <String>['id', 'name'],
      ))
        row['name']! as String: row['id']! as int,
    };

    for (final PantryRecipe recipe in PantrySeed.recipes) {
      final List<Map<String, Object?>> rows = await txn.rawQuery(
        '''
        SELECT r.id AS recipe_id, v.id AS version_id,
               (SELECT COUNT(*) FROM recipe_versions WHERE recipe_id = r.id)
                 AS versions
        FROM recipes r
        JOIN recipe_versions v ON v.recipe_id = r.id
        JOIN products p ON p.id = r.product_id
        JOIN sizes s ON s.id = r.size_id
        WHERE p.name = ? COLLATE NOCASE AND s.name = ? COLLATE NOCASE
          AND v.note = ?
        LIMIT 1
        ''',
        <Object?>[recipe.drink, recipe.size, _fromWorksheet],
      );
      // Not there, or she has saved a version of her own over it.
      if (rows.isEmpty || (rows.first['versions']! as int) > 1) continue;

      final int versionId = rows.first['version_id']! as int;
      await txn.delete(
        'recipe_items',
        where: 'recipe_version_id = ?',
        whereArgs: <Object?>[versionId],
      );
      await _writeLines(txn, versionId, recipe, ingredientIds, now);
      await txn.update(
        'recipe_versions',
        <String, Object?>{'updated_at': now},
        where: 'id = ?',
        whereArgs: <Object?>[versionId],
      );
    }
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

    await _writeOptionEffects(txn);

    // The prices off her sheet are where the running average starts.
    await const MovingAverageCost().rebuildAll(txn);
  }

  /// What each customisation adds to, or takes out of, the drink.
  ///
  /// Written straight over whatever is there: these are transcriptions of her
  /// sheet, not decisions anyone has made in the app. An effect naming a
  /// drink or an option the shop does not have is skipped rather than
  /// guessed at.
  Future<void> _writeOptionEffects(Transaction txn) async {
    final String now = _clock.nowIso();

    for (final OptionEffect effect in OptionEffectsSeed.effects) {
      final int? optionId = await _optionId(txn, effect.option);
      final int? ingredientId = await _ingredientId(txn, effect.ingredient);
      if (optionId == null || ingredientId == null) continue;

      int? productId;
      int? sizeId;
      if (effect.drink != null) {
        productId = await _productId(txn, effect.drink!);
        sizeId = await _sizeId(txn, effect.size!);
        if (productId == null || sizeId == null) continue;
      }

      final BaseUnit unit = await _unitOf(txn, ingredientId);
      await txn.insert('option_ingredient_effects', <String, Object?>{
        'option_id': optionId,
        'ingredient_id': ingredientId,
        'product_id': productId,
        'size_id': sizeId,
        'qty_milli_delta':
            Quantity.fromBase(effect.amount.abs(), unit).milli *
            (effect.amount.isNegative ? -1 : 1),
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<int?> _optionId(Transaction txn, String name) async {
    final List<Map<String, Object?>> rows = await txn.query(
      'customization_options',
      columns: <String>['id'],
      where: 'name = ? COLLATE NOCASE AND is_active = 1',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id']! as int;
  }

  Future<int?> _ingredientId(Transaction txn, String name) async {
    final List<Map<String, Object?>> rows = await txn.query(
      'ingredients',
      columns: <String>['id'],
      where: 'name = ? COLLATE NOCASE',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id']! as int;
  }

  Future<int?> _productId(Transaction txn, String name) async {
    final List<Map<String, Object?>> rows = await txn.query(
      'products',
      columns: <String>['id'],
      where: 'name = ? COLLATE NOCASE',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id']! as int;
  }

  Future<int?> _sizeId(Transaction txn, String name) async {
    final List<Map<String, Object?>> rows = await txn.query(
      'sizes',
      columns: <String>['id'],
      where: 'name = ? COLLATE NOCASE',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id']! as int;
  }

  Future<BaseUnit> _unitOf(Transaction txn, int ingredientId) async {
    final List<Map<String, Object?>> rows = await txn.query(
      'ingredients',
      columns: <String>['base_unit'],
      where: 'id = ?',
      whereArgs: <Object?>[ingredientId],
      limit: 1,
    );
    return BaseUnit.fromCode(rows.first['base_unit']! as String);
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
      'note': _fromWorksheet,
      'created_at': now,
      'updated_at': now,
    });

    await _writeLines(txn, versionId, recipe, ingredientIds, now);
  }

  Future<void> _writeLines(
    Transaction txn,
    int versionId,
    PantryRecipe recipe,
    Map<String, int> ingredientIds,
    String now,
  ) async {
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
