import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// What a customisation does to the recipe can depend on the drink.
///
/// "Sea Salt Cold Foam" adds the same cream, milk and salt to whatever it is
/// poured on, so one rule covers every drink. "Sub Oat" cannot: it takes out
/// the milk *that drink* uses and puts the same weight of oat in, and a
/// Spanish Latte and a Caramel Macchiato do not hold the same milk.
///
/// So an effect may now name a product and a size. One with neither applies
/// everywhere, exactly as before.
class M011OptionEffectsPerDrink extends Migration {
  const M011OptionEffectsPerDrink();

  @override
  int get version => 11;

  @override
  String get name => 'option_effects_per_drink';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await db.execute(
      'ALTER TABLE option_ingredient_effects ADD COLUMN product_id INTEGER '
      'REFERENCES products(id) ON DELETE CASCADE',
    );
    await db.execute(
      'ALTER TABLE option_ingredient_effects ADD COLUMN size_id INTEGER '
      'REFERENCES sizes(id) ON DELETE CASCADE',
    );

    // The old index allowed one row per option and ingredient. There can now
    // be one per drink and size as well. COALESCE keeps the uniqueness real:
    // SQLite treats two NULLs as different, so a plain index over nullable
    // columns would let the same global rule be written twice.
    await db.execute('DROP INDEX IF EXISTS idx_option_effects_unique');
    await db.execute(
      'CREATE UNIQUE INDEX idx_option_effects_unique '
      'ON option_ingredient_effects('
      'option_id, ingredient_id, '
      'COALESCE(product_id, -1), COALESCE(size_id, -1))',
    );
    await db.execute(
      'CREATE INDEX idx_option_effects_product '
      'ON option_ingredient_effects(product_id, size_id)',
    );
  }
}
