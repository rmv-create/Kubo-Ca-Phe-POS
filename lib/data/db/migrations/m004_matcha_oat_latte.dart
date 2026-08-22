import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// The Matcha Latte becomes the **Matcha Oat Latte**: ₱139 small, ₱149 grande,
/// made with oat milk at no extra charge.
///
/// The last part needs a new idea. Oat costs ₱20 as an upgrade on every other
/// drink, because on every other drink it *is* an upgrade — but on a drink
/// whose name is "oat latte" it is simply what the drink is made of. So a
/// product can now override the price of one option, and this drink overrides
/// oat to zero.
///
/// The alternative — dropping oat's price everywhere, or giving this drink its
/// own private milk group — would either lose ₱20 on every Spanish Latte or
/// duplicate a group that has to be maintained twice.
///
/// A shop that has already been trading keeps every past order exactly as it
/// was sold: those lines carry their own price and name snapshots, so a Matcha
/// Latte bought yesterday at ₱139 still reads that way.
class M004MatchaOatLatte extends Migration {
  const M004MatchaOatLatte();

  @override
  int get version => 4;

  @override
  String get name => 'matcha_oat_latte';

  static const String _oldName = 'Matcha Latte';
  static const String _newName = 'Matcha Oat Latte';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await _optionPriceOverrides(db);

    final int? productId = await _findProduct(db);
    // A database seeded after this migration ships will already have the drink
    // under its new name and price; there is nothing to change.
    if (productId == null) return;

    await _rename(db, productId);
    await _reprice(db, productId);
    await _makeItOat(db, productId);
  }

  Future<void> _optionPriceOverrides(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE product_option_prices (
        id                   INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id           INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        option_id            INTEGER NOT NULL REFERENCES customization_options(id) ON DELETE CASCADE,
        price_delta_centavos INTEGER NOT NULL,
        created_at           TEXT NOT NULL,
        updated_at           TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX idx_product_option_prices_unique '
      'ON product_option_prices(product_id, option_id)',
    );
  }

  Future<int?> _findProduct(DatabaseExecutor db) async {
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT id FROM products WHERE name = ? LIMIT 1',
      <Object?>[_oldName],
    );
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  Future<void> _rename(DatabaseExecutor db, int productId) async {
    await db.rawUpdate(
      "UPDATE products SET name = ?, description = ?, "
      "updated_at = datetime('now') WHERE id = ?",
      <Object?>[
        _newName,
        'Vibrant matcha with creamy oat milk. Smooth, earthy and lightly '
            'sweet.',
        productId,
      ],
    );
  }

  Future<void> _reprice(DatabaseExecutor db, int productId) async {
    const Map<String, int> prices = <String, int>{
      'small': 13900,
      'grande': 14900,
    };
    for (final MapEntry<String, int> entry in prices.entries) {
      await db.rawUpdate(
        'UPDATE product_sizes SET price_centavos = ? '
        'WHERE product_id = ? '
        'AND size_id = (SELECT id FROM sizes WHERE code = ?)',
        <Object?>[entry.value, productId, entry.key],
      );
    }
  }

  /// Oat becomes the default milk on this drink, and free on this drink only.
  Future<void> _makeItOat(DatabaseExecutor db, int productId) async {
    final List<Map<String, Object?>> oatRows = await db.rawQuery('''
      SELECT o.id FROM customization_options o
      JOIN customization_groups g ON g.id = o.group_id
      WHERE g.code = 'milk' AND o.name = 'Oat'
      LIMIT 1
      ''');
    if (oatRows.isEmpty) return;
    final int oatId = oatRows.first['id']! as int;

    // Oat costs nothing here. It is the drink, not an upgrade to it.
    await db.rawInsert(
      'INSERT INTO product_option_prices '
      '(product_id, option_id, price_delta_centavos, created_at, updated_at) '
      "VALUES (?, ?, 0, datetime('now'), datetime('now'))",
      <Object?>[productId, oatId],
    );

    // Replace whichever milk was the default with oat, for every size.
    await db.rawDelete(
      '''
      DELETE FROM product_default_options
      WHERE product_id = ?
        AND option_id IN (
          SELECT o.id FROM customization_options o
          JOIN customization_groups g ON g.id = o.group_id
          WHERE g.code = 'milk'
        )
      ''',
      <Object?>[productId],
    );
    await db.rawInsert(
      'INSERT INTO product_default_options '
      '(product_id, size_id, option_id, created_at, updated_at) '
      "VALUES (?, NULL, ?, datetime('now'), datetime('now'))",
      <Object?>[productId, oatId],
    );
  }
}
