import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/migrations/migration_runner.dart';
import 'package:kubo_pos/data/db/seed/menu_seeder.dart';

import '../support/test_database.dart';

/// Migration 6 puts her menu card's own names and prices onto a shop that has
/// already been trading.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The prices of every drink in a database, as name → [small, grande].
  Future<Map<String, List<int>>> menuOf(AppDatabase db) async {
    final List<Map<String, Object?>> rows = await db.db.rawQuery('''
      SELECT p.name AS name, s.name AS size, ps.price_centavos AS price
      FROM product_sizes ps
      JOIN products p ON p.id = ps.product_id
      JOIN sizes s ON s.id = ps.size_id
      ''');
    final Map<String, List<int>> menu = <String, List<int>>{};
    for (final Map<String, Object?> row in rows) {
      final List<int> prices = menu.putIfAbsent(
        row['name']! as String,
        () => <int>[0, 0],
      );
      prices[row['size'] == 'Small' ? 0 : 1] = row['price']! as int;
    }
    return menu;
  }

  /// A shop as it stood before this migration: the old names, the old prices,
  /// and one sale already rung up against them.
  Future<AppDatabase> tradingShopOnVersion5() async {
    final AppDatabase db = await openTestDatabaseAt(5);
    addTearDown(db.close);
    const String at = '2026-03-15T02:00:00Z';

    Future<int> insert(String table, Map<String, Object?> values) =>
        db.db.insert(table, <String, Object?>{
          ...values,
          'created_at': at,
          'updated_at': at,
        });

    final int classics = await insert('product_categories', <String, Object?>{
      'name': 'Classics',
      'display_order': 0,
    });
    await insert('product_categories', <String, Object?>{
      'name': 'Specialty Coffee',
      'display_order': 1,
    });
    final int small = await insert('sizes', <String, Object?>{
      'code': 'small',
      'name': 'Small',
      'volume_oz': 12,
      'display_order': 0,
    });
    // Still called Grande here: this is the database as it stood before the
    // rename, which is the whole point of the fixture.
    final int grande = await insert('sizes', <String, Object?>{
      'code': 'grande',
      'name': 'Grande',
      'volume_oz': 16,
      'display_order': 1,
    });

    final int black = await insert('products', <String, Object?>{
      'category_id': classics,
      'name': 'Black',
      'description': 'The old wording.',
      'display_order': 0,
    });
    for (final (int size, int price) in <(int, int)>[
      (small, 12900),
      (grande, 13900),
    ]) {
      await insert('product_sizes', <String, Object?>{
        'product_id': black,
        'size_id': size,
        'price_centavos': price,
        'is_available': 1,
        'is_default_size': size == grande ? 1 : 0,
      });
    }

    // Yesterday's sale, at yesterday's price.
    final int orderId = await db.db.insert('orders', <String, Object?>{
      'order_no': 'K-0001',
      'created_at': at,
      'business_date': '2026-03-15',
      'status': 'completed',
      'total_centavos': 13900,
    });
    await db.db.insert('order_items', <String, Object?>{
      'order_id': orderId,
      'line_no': 1,
      'product_id': black,
      'product_name_snapshot': 'Black',
      'size_id': grande,
      'size_name_snapshot': 'Grande',
      'size_volume_oz_snapshot': 16,
      'quantity': 1,
      'unit_base_price_centavos': 13900,
      'unit_price_centavos': 13900,
      'line_total_centavos': 13900,
    });

    return db;
  }

  test('a drink the card renamed keeps its identity, not its name', () async {
    final AppDatabase db = await tradingShopOnVersion5();

    await const MigrationRunner().run(db.db);

    final List<Map<String, Object?>> products = await db.db.query(
      'products',
      where: 'name IN (?, ?)',
      whereArgs: <Object?>['Black', 'Iced Black'],
    );
    expect(products.map((Map<String, Object?> p) => p['name']), <String>[
      'Iced Black',
    ], reason: 'renamed in place — not left behind and duplicated');
    expect(products.single['description'], isNot('The old wording.'));
  });

  test('the new prices apply, the old sale does not move', () async {
    final AppDatabase db = await tradingShopOnVersion5();

    await const MigrationRunner().run(db.db);

    expect((await menuOf(db))['Iced Black'], <int>[10900, 12900]);

    // The receipt for yesterday's coffee must still read what she charged.
    final Map<String, Object?> line = (await db.db.query('order_items')).single;
    expect(line['product_name_snapshot'], 'Black');
    expect(line['unit_base_price_centavos'], 13900);
    expect(line['line_total_centavos'], 13900);
    expect(
      (await db.db.query('orders')).single['total_centavos'],
      13900,
      reason: 'changing the menu never re-prices a sale',
    );
  });

  test('drinks the app never had are added, once', () async {
    final AppDatabase db = await tradingShopOnVersion5();

    await const MigrationRunner().run(db.db);

    final Map<String, List<int>> menu = await menuOf(db);
    expect(menu['Cinnamon Oat Latte'], <int>[12900, 14900]);
    expect(menu['Sea Salt Matcha Oat Latte'], <int>[16900, 18900]);

    // Running it again would be the easy way to double the menu.
    await const MigrationRunner().run(db.db);
    final List<Map<String, Object?>> again = await db.db.query(
      'products',
      where: 'name = ?',
      whereArgs: <Object?>['Cinnamon Oat Latte'],
    );
    expect(again, hasLength(1));
  });

  test('a drink she added herself is re-priced, not duplicated', () async {
    final AppDatabase db = await openTestDatabaseAt(5);
    addTearDown(db.close);
    const String at = '2026-03-15T02:00:00Z';

    final int classics = await db.db.insert(
      'product_categories',
      <String, Object?>{
        'name': 'Classics',
        'display_order': 0,
        'created_at': at,
        'updated_at': at,
      },
    );
    final int grande = await db.db.insert('sizes', <String, Object?>{
      'code': 'grande',
      'name': 'Grande',
      'volume_oz': 16,
      'display_order': 1,
      'created_at': at,
      'updated_at': at,
    });
    await db.db.insert('product_categories', <String, Object?>{
      'name': 'Specialty Coffee',
      'display_order': 1,
      'created_at': at,
      'updated_at': at,
    });
    // She added this one in the app before the migration shipped, at a price
    // she typed in herself.
    final int hers = await db.db.insert('products', <String, Object?>{
      'category_id': classics,
      'name': 'Cinnamon Oat Latte',
      'display_order': 1,
      'created_at': at,
      'updated_at': at,
    });
    await db.db.insert('product_sizes', <String, Object?>{
      'product_id': hers,
      'size_id': grande,
      'price_centavos': 14000,
      'is_available': 1,
      'is_default_size': 1,
      'created_at': at,
      'updated_at': at,
    });

    await const MigrationRunner().run(db.db);

    final List<Map<String, Object?>> products = await db.db.query(
      'products',
      where: 'name = ?',
      whereArgs: <Object?>['Cinnamon Oat Latte'],
    );
    expect(products, hasLength(1));
    expect(products.single['id'], hers, reason: 'hers, re-priced in place');
    expect((await menuOf(db))['Cinnamon Oat Latte']![1], 14900);
  });

  test('the choices her card does not have are retired, not deleted', () async {
    final AppDatabase db = await openTestDatabaseAt(7);
    addTearDown(db.close);
    const String at = '2026-03-15T02:00:00Z';

    final int classics = await db.db.insert(
      'product_categories',
      <String, Object?>{
        'name': 'Classics',
        'display_order': 0,
        'created_at': at,
        'updated_at': at,
      },
    );
    final int product = await db.db.insert('products', <String, Object?>{
      'category_id': classics,
      'name': 'Spanish Latte',
      'display_order': 0,
      'created_at': at,
      'updated_at': at,
    });
    final int syrup = await db.db
        .insert('customization_groups', <String, Object?>{
          'code': 'syrup',
          'name': 'Syrup',
          'selection_type': 'single',
          'is_required': 0,
          'is_proactive': 0,
          'display_order': 3,
          'is_active': 1,
          'created_at': at,
          'updated_at': at,
        });
    final int vanilla = await db.db
        .insert('customization_options', <String, Object?>{
          'group_id': syrup,
          'name': 'Vanilla',
          'price_delta_centavos': 3000,
          'display_order': 1,
          'is_active': 1,
          'created_at': at,
          'updated_at': at,
        });
    await db.db.insert('product_customization_groups', <String, Object?>{
      'product_id': product,
      'group_id': syrup,
      'is_visible': 1,
      'display_order': 3,
      'created_at': at,
      'updated_at': at,
    });
    final int extras = await db.db
        .insert('customization_groups', <String, Object?>{
          'code': 'extras',
          'name': 'Extras',
          'selection_type': 'multi',
          'is_required': 0,
          'is_proactive': 0,
          'display_order': 5,
          'is_active': 1,
          'created_at': at,
          'updated_at': at,
        });
    await db.db.insert('customization_options', <String, Object?>{
      'group_id': extras,
      'name': 'Sea Salt Cream',
      'price_delta_centavos': 2000,
      'display_order': 0,
      'is_active': 1,
      'created_at': at,
      'updated_at': at,
    });

    await const MigrationRunner().run(db.db);

    // Switched off and unhooked from every drink, but still on the record —
    // an order that carried a Vanilla syrup must still print as it was sold.
    final Map<String, Object?> group = (await db.db.query(
      'customization_groups',
      where: 'code = ?',
      whereArgs: <Object?>['syrup'],
    )).single;
    expect(group['is_active'], 0);
    expect(
      await db.db.query(
        'product_customization_groups',
        where: 'group_id = ?',
        whereArgs: <Object?>[syrup],
      ),
      isEmpty,
    );
    expect(
      await db.db.query(
        'customization_options',
        where: 'id = ?',
        whereArgs: <Object?>[vanilla],
      ),
      hasLength(1),
    );

    // The extras become the two the card prices, the first renamed in place
    // so orders already carrying it still point at it.
    final List<Map<String, Object?>> offered = await db.db.query(
      'customization_options',
      where: 'group_id = ? AND is_active = 1',
      whereArgs: <Object?>[extras],
      orderBy: 'display_order',
    );
    expect(offered.map((Map<String, Object?> o) => o['name']), <String>[
      'Sea Salt Cold Foam',
      '1g Matcha',
    ]);
    expect(offered.last['price_delta_centavos'], 1500);
  });

  test('Grande becomes Large without moving anything', () async {
    final AppDatabase db = await tradingShopOnVersion5();

    await const MigrationRunner().run(db.db);

    final Map<String, Object?> size = (await db.db.query(
      'sizes',
      where: 'code = ?',
      whereArgs: <Object?>['large'],
    )).single;
    expect(size['name'], 'Large');
    expect(size['volume_oz'], 16);
    expect(
      await db.db.query(
        'sizes',
        where: 'name = ?',
        whereArgs: <Object?>['Grande'],
      ),
      isEmpty,
    );

    // The same row, so prices and recipes still point at it — and the order
    // already sold keeps the name it was sold under.
    expect((await menuOf(db))['Iced Black'], <int>[10900, 12900]);
    expect(
      (await db.db.query('order_items')).single['size_name_snapshot'],
      'Grande',
    );
  });

  test('the ways she takes money are all there', () async {
    final AppDatabase db = await tradingShopOnVersion5();

    await const MigrationRunner().run(db.db);

    final List<Map<String, Object?>> methods = await db.db.query(
      'payment_methods',
      where: 'is_active = 1',
      orderBy: 'display_order',
    );
    expect(methods.map((Map<String, Object?> m) => m['name']), <String>[
      'Cash',
      'GCash',
      'Maya',
      'MariBank',
      'BPI',
    ]);
    // Only cash can work out change; everything else lands where the POS
    // cannot see it and has to be confirmed.
    expect(methods.first['takes_tendered'], 1);
    expect(methods.last['needs_confirmation'], 1);
  });

  test('an upgraded shop and a new one end up with the same menu', () async {
    // The migration carries its own frozen copy of the card so that it does
    // the same thing in a year as it does today. This is what stops that copy
    // drifting away from the one a fresh install is seeded with.
    final AppDatabase upgraded = await tradingShopOnVersion5();
    await const MigrationRunner().run(upgraded.db);

    final AppDatabase fresh = await openTestDatabase();
    addTearDown(fresh.close);
    await MenuSeeder(fresh, testClock()).seedIfEmpty();

    expect(await menuOf(upgraded), await menuOf(fresh));
  });
}
