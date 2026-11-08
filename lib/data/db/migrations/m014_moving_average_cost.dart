import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// What the stock on the shelf actually cost.
///
/// "Weighted average" used to mean the average of every delivery ever
/// recorded, which quietly counts milk drunk months ago. What it should mean
/// — and what this table holds — is a *moving* average: whatever is still on
/// the shelf at its cost, plus what just arrived at its cost, over the total.
///
/// Six litres at ₱125 with ten more at ₱115 is ₱118.75 a litre. Sell five of
/// the old ones first and the same delivery lands at ₱115.91, because only
/// one litre of the dear milk is still there to average against.
///
/// Every row is one moment the average moved: a delivery, or the owner typing
/// a cost in by hand. Nothing here is typed by a person and nothing here is
/// sent between tills — the whole table is rebuilt from the deliveries and
/// the stock ledger, the same way the running stock total is.
class M014MovingAverageCost extends Migration {
  const M014MovingAverageCost();

  @override
  int get version => 14;

  @override
  String get name => 'moving_average_cost';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE ingredient_avg_cost (
        id                 INTEGER PRIMARY KEY AUTOINCREMENT,
        ingredient_id      INTEGER NOT NULL
                             REFERENCES ingredients(id) ON DELETE CASCADE,
        effective_from     TEXT NOT NULL,
        source             TEXT NOT NULL
                             CHECK (source IN ('purchase', 'manual', 'seed')),
        qty_before_milli   INTEGER NOT NULL DEFAULT 0,
        qty_added_milli    INTEGER NOT NULL DEFAULT 0,
        avg_before_centavos_per_1000_base INTEGER NOT NULL DEFAULT 0,
        avg_after_centavos_per_1000_base  INTEGER NOT NULL
                             CHECK (avg_after_centavos_per_1000_base >= 0),
        purchase_item_id   INTEGER
                             REFERENCES purchase_items(id) ON DELETE CASCADE,
        created_at         TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX idx_ingredient_avg_cost_lookup
        ON ingredient_avg_cost(ingredient_id, effective_from DESC, id DESC)
    ''');
  }
}
