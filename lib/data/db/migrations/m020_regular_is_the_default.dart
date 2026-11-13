import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Says out loud that a drink comes at regular strength and regular
/// sweetness.
///
/// Milk and ice always knew what the drink came with; strength and sweetness
/// never did. Nothing was wrong with the drinks — "Regular" was offered and
/// picked like any other choice — but because nobody had written down that
/// it was the one the drink comes with anyway, the app could not tell a cup
/// nobody changed from a cup somebody asked to be left alone. So the receipt
/// printed it, and a customer read "Regular sweetness · Regular strength"
/// under a drink that was simply what it says on the menu.
///
/// Marking it is the honest fix rather than teaching the receipt to ignore
/// the word "Regular": the app now knows what the drink is, and everything
/// that follows from that — what gets printed, what the POS offers first —
/// follows on its own.
///
/// Nothing already sold changes. Each order carries its own record of what
/// was chosen and whether it was a default at the time.
class M020RegularIsTheDefault extends Migration {
  const M020RegularIsTheDefault();

  @override
  int get version => 20;

  @override
  String get name => 'regular_is_the_default';

  @override
  Future<void> up(DatabaseExecutor db) async {
    final String now = DateTime.now().toUtc().toIso8601String();

    // Only where she has not already chosen a default of her own for that
    // group on that drink: her own answer always wins over this one.
    await db.rawInsert(
      '''
      INSERT OR IGNORE INTO product_default_options
        (product_id, size_id, option_id, created_at, updated_at)
      SELECT pcg.product_id, NULL, o.id, ?, ?
      FROM product_customization_groups pcg
      JOIN customization_groups g
        ON g.id = pcg.group_id AND g.code IN ('strength', 'sweetness')
      JOIN customization_options o
        ON o.group_id = g.id AND o.name = 'Regular'
      WHERE NOT EXISTS (
        SELECT 1 FROM product_default_options d
        JOIN customization_options od ON od.id = d.option_id
        WHERE d.product_id = pcg.product_id AND od.group_id = g.id
      )
      ''',
      <Object?>[now, now],
    );
  }
}
