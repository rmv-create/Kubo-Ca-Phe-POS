import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import '../../core/quantity/measurement_unit.dart';
import '../../core/quantity/quantity.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/recipe.dart';
import '../../domain/repositories/inventory_repository.dart';
import '../../domain/repositories/recipe_repository.dart';
import '../db/app_database.dart';

class RecipeRepositoryImpl implements RecipeRepository {
  RecipeRepositoryImpl(this._db, this._clock, this._inventory);

  final AppDatabase _db;
  final Clock _clock;
  final InventoryRepository _inventory;

  @override
  Future<List<Recipe>> recipes({bool withCosts = true}) async {
    // Every product/size pair, so a drink with no recipe yet is visible rather
    // than silently missing from the list.
    final List<Map<String, Object?>> pairs = await _db.db.rawQuery('''
      SELECT ps.product_id AS product_id, ps.size_id AS size_id,
             p.name AS product_name, s.name AS size_name,
             s.volume_oz AS volume_oz, s.display_order AS size_order,
             p.display_order AS product_order,
             r.id AS recipe_id, r.notes AS notes
      FROM product_sizes ps
      JOIN products p ON p.id = ps.product_id
      JOIN sizes s ON s.id = ps.size_id
      LEFT JOIN recipes r
             ON r.product_id = ps.product_id AND r.size_id = ps.size_id
      WHERE p.is_archived = 0
      ORDER BY p.display_order, p.name COLLATE NOCASE, s.display_order
    ''');

    final Map<int, Ingredient> byId = withCosts
        ? <int, Ingredient>{
            for (final Ingredient i in await _inventory.ingredients(
              includeInactive: true,
            ))
              i.id: i,
          }
        : <int, Ingredient>{};

    final List<Recipe> recipes = <Recipe>[];
    for (final Map<String, Object?> row in pairs) {
      final int? recipeId = row['recipe_id'] as int?;
      recipes.add(
        Recipe(
          id: recipeId ?? 0,
          productId: row['product_id']! as int,
          productName: row['product_name']! as String,
          sizeId: row['size_id']! as int,
          sizeName: row['size_name']! as String,
          sizeVolumeOz: (row['volume_oz']! as num).toDouble(),
          notes: row['notes'] as String?,
          versions: recipeId == null
              ? const <RecipeVersion>[]
              : await _versionsFor(recipeId, byId),
        ),
      );
    }
    return recipes;
  }

  @override
  Future<Recipe?> recipeFor({
    required int productId,
    required int sizeId,
    bool withCosts = true,
  }) async {
    final List<Recipe> all = await recipes(withCosts: withCosts);
    for (final Recipe r in all) {
      if (r.productId == productId && r.sizeId == sizeId) return r;
    }
    return null;
  }

  @override
  Future<int> saveVersion({
    required int productId,
    required int sizeId,
    required Map<int, Quantity> lines,
    String? note,
  }) async {
    if (lines.isEmpty) {
      throw const ValidationException(
        'A recipe needs at least one ingredient.',
      );
    }
    final String now = _clock.nowIso();

    return _db.transaction<int>((Transaction txn) async {
      int recipeId;
      final List<Map<String, Object?>> existing = await txn.query(
        'recipes',
        columns: <String>['id'],
        where: 'product_id = ? AND size_id = ?',
        whereArgs: <Object?>[productId, sizeId],
        limit: 1,
      );
      if (existing.isEmpty) {
        recipeId = await txn.insert('recipes', <String, Object?>{
          'product_id': productId,
          'size_id': sizeId,
          'created_at': now,
          'updated_at': now,
        });
      } else {
        recipeId = existing.first['id']! as int;
      }

      // Close the version that is live, rather than editing it. Orders already
      // sold keep the ingredients and the cost they were sold at.
      await txn.update(
        'recipe_versions',
        <String, Object?>{
          'effective_to': now,
          'status': RecipeStatus.retired.code,
          'updated_at': now,
        },
        where: 'recipe_id = ? AND effective_to IS NULL AND status = ?',
        whereArgs: <Object?>[recipeId, RecipeStatus.active.code],
      );

      final List<Map<String, Object?>> lastVersion = await txn.rawQuery(
        'SELECT MAX(version_no) AS m FROM recipe_versions WHERE recipe_id = ?',
        <Object?>[recipeId],
      );
      final int versionNo = ((lastVersion.first['m'] as int?) ?? 0) + 1;

      final int versionId = await txn
          .insert('recipe_versions', <String, Object?>{
            'recipe_id': recipeId,
            'version_no': versionNo,
            'effective_from': now,
            'effective_to': null,
            'status': RecipeStatus.active.code,
            'note': note,
            'created_at': now,
            'updated_at': now,
          });

      for (final MapEntry<int, Quantity> line in lines.entries) {
        if (!line.value.isPositive) continue;
        await txn.insert('recipe_items', <String, Object?>{
          'recipe_version_id': versionId,
          'ingredient_id': line.key,
          'qty_milli': line.value.milli,
          'created_at': now,
        });
      }

      await txn.insert('audit_log', <String, Object?>{
        'at': now,
        'business_date': now.substring(0, 10),
        'action': 'recipe_version_saved',
        'entity_type': 'recipe_version',
        'entity_id': versionId,
        'summary':
            'Recipe v$versionNo saved with '
            '${lines.length} ingredient${lines.length == 1 ? '' : 's'}',
      });

      return versionId;
    });
  }

  @override
  Future<void> retireVersion(int versionId) async {
    final String now = _clock.nowIso();
    await _db.db.update(
      'recipe_versions',
      <String, Object?>{
        'status': RecipeStatus.retired.code,
        'effective_to': now,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: <Object?>[versionId],
    );
  }

  Future<List<RecipeVersion>> _versionsFor(
    int recipeId,
    Map<int, Ingredient> ingredientsById,
  ) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'recipe_versions',
      where: 'recipe_id = ?',
      whereArgs: <Object?>[recipeId],
      orderBy: 'version_no DESC',
    );

    final List<RecipeVersion> versions = <RecipeVersion>[];
    for (final Map<String, Object?> row in rows) {
      final int versionId = row['id']! as int;
      final List<Map<String, Object?>> lineRows = await _db.db.rawQuery(
        'SELECT ri.*, i.name AS ingredient_name, i.base_unit AS base_unit '
        'FROM recipe_items ri '
        'JOIN ingredients i ON i.id = ri.ingredient_id '
        'WHERE ri.recipe_version_id = ? '
        'ORDER BY i.name COLLATE NOCASE',
        <Object?>[versionId],
      );

      versions.add(
        RecipeVersion(
          id: versionId,
          recipeId: recipeId,
          versionNo: row['version_no']! as int,
          effectiveFrom: DateTime.parse(row['effective_from']! as String),
          effectiveTo: row['effective_to'] == null
              ? null
              : DateTime.parse(row['effective_to']! as String),
          status: RecipeStatus.fromCode(row['status']! as String),
          note: row['note'] as String?,
          lines: lineRows.map((Map<String, Object?> l) {
            final int ingredientId = l['ingredient_id']! as int;
            final Ingredient? ingredient = ingredientsById[ingredientId];
            return RecipeLine(
              id: l['id']! as int,
              ingredientId: ingredientId,
              ingredientName: l['ingredient_name']! as String,
              // The unit comes from the query rather than the cached
              // ingredient, so a recipe still reads correctly when costs were
              // not asked for.
              quantity: Quantity(
                l['qty_milli']! as int,
                BaseUnit.fromCode(l['base_unit']! as String),
              ),
              note: l['note'] as String?,
              ingredient: ingredient,
            );
          }).toList(),
        ),
      );
    }
    return versions;
  }
}
