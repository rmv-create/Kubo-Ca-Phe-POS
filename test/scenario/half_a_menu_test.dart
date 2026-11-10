import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/seed/menu_seeder.dart';

import '../support/test_database.dart';

/// Her sister's phone, which signed in and got four drinks of six.
///
/// The owner's till had pushed only part of the shop when the second phone
/// asked for it, so the menu arrived real but incomplete — and every seeder
/// in the app only asks whether the table is empty, so nothing would ever
/// have finished it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() async {
    db = await openTestDatabase();
    await MenuSeeder(db, testClock()).seedIfEmpty();
  });
  tearDown(() async => db.close());

  Future<int> count(String table, [String? where]) async {
    final List<Map<String, Object?>> rows = await db.db.rawQuery(
      'SELECT COUNT(*) n FROM $table${where == null ? '' : ' WHERE $where'}',
    );
    return rows.first['n']! as int;
  }

  Future<List<String>> drinkNames() async => (await db.db.rawQuery(
    'SELECT name FROM products ORDER BY name',
  )).map((Map<String, Object?> r) => r['name']! as String).toList();

  /// Exactly what she saw: two drinks never arrived, and two more arrived
  /// with only one of their two sizes.
  Future<void> arriveInPieces() async {
    for (final String gone in <String>['Spanish Latte', 'Cinnamon Oat Latte']) {
      final int id =
          (await db.db.query(
                'products',
                columns: <String>['id'],
                where: 'name = ?',
                whereArgs: <Object?>[gone],
              )).first['id']!
              as int;
      await db.db.delete(
        'product_sizes',
        where: 'product_id = ?',
        whereArgs: <Object?>[id],
      );
      await db.db.delete('products', where: 'id = ?', whereArgs: <Object?>[id]);
    }
    final int large =
        (await db.db.query(
              'sizes',
              columns: <String>['id'],
              where: 'code = ?',
              whereArgs: <Object?>['large'],
            )).first['id']!
            as int;
    for (final String half in <String>['Iced Black', 'Caramel Macchiato']) {
      final int id =
          (await db.db.query(
                'products',
                columns: <String>['id'],
                where: 'name = ?',
                whereArgs: <Object?>[half],
              )).first['id']!
              as int;
      await db.db.delete(
        'product_sizes',
        where: 'product_id = ? AND size_id = ?',
        whereArgs: <Object?>[id, large],
      );
    }
  }

  test('a menu that arrived in pieces is finished, not left', () async {
    await arriveInPieces();
    expect(await count('products'), 7);

    final int added = await MenuSeeder(db, testClock()).repairMissing();

    expect(added, greaterThan(0));
    expect(await count('products'), 9);
    expect(await drinkNames(), contains('Spanish Latte'));
    expect(await drinkNames(), contains('Cinnamon Oat Latte'));
    // Every drink has both sizes again.
    expect(await count('product_sizes'), 18);
  });

  test('the drinks it puts back are whole', () async {
    await arriveInPieces();
    await MenuSeeder(db, testClock()).repairMissing();

    final List<Map<String, Object?>> rows = await db.db.rawQuery('''
      SELECT z.name size, ps.price_centavos price
      FROM products p
      JOIN product_sizes ps ON ps.product_id = p.id
      JOIN sizes z ON z.id = ps.size_id
      WHERE p.name = 'Spanish Latte'
      ORDER BY z.code
    ''');
    expect(rows.length, 2);
    expect(rows.map((Map<String, Object?> r) => r['price']), <int>[
      13900,
      11900,
    ]);

    // And it comes back able to be ordered, not as a bare row.
    final int rules = await count(
      'product_customization_groups',
      "product_id = (SELECT id FROM products WHERE name = 'Spanish Latte')",
    );
    expect(rules, greaterThan(0));
  });

  test('it changes nothing on a phone whose menu is already whole', () async {
    final int before = await count('products');
    final int sizes = await count('product_sizes');
    final int rules = await count('product_customization_groups');

    expect(await MenuSeeder(db, testClock()).repairMissing(), 0);

    expect(await count('products'), before);
    expect(await count('product_sizes'), sizes);
    expect(await count('product_customization_groups'), rules);
  });

  test('a price she changed herself is never written back', () async {
    await db.db.rawUpdate(
      'UPDATE product_sizes SET price_centavos = 15500 WHERE product_id = '
      '(SELECT id FROM products WHERE name = \'Iced Black\')',
    );
    await arriveInPieces();

    await MenuSeeder(db, testClock()).repairMissing();

    final List<Map<String, Object?>> rows = await db.db.rawQuery(
      'SELECT price_centavos p FROM product_sizes WHERE product_id = '
      '(SELECT id FROM products WHERE name = \'Iced Black\') ORDER BY p',
    );
    // Her Small stands as she set it; only the missing Large is added back.
    expect(rows.map((Map<String, Object?> r) => r['p']), contains(15500));
  });

  test('a drink she took off the menu stays off it', () async {
    await db.db.rawUpdate(
      'UPDATE products SET is_archived = 1 '
      'WHERE name = \'Ca Phe Trung\'',
    );

    await MenuSeeder(db, testClock()).repairMissing();

    final List<Map<String, Object?>> rows = await db.db.query(
      'products',
      columns: <String>['is_archived'],
      where: 'name = ?',
      whereArgs: <Object?>['Ca Phe Trung'],
    );
    expect(rows.length, 1, reason: 'not a second copy beside the archived one');
    expect(rows.first['is_archived'], 1);
  });

  test('no Vietnamese coffee asks which milk', () async {
    final List<Map<String, Object?>> rows = await db.db.rawQuery('''
      SELECT p.name FROM product_customization_groups pcg
      JOIN products p ON p.id = pcg.product_id
      JOIN product_categories c ON c.id = p.category_id
      JOIN customization_groups g ON g.id = pcg.group_id
      WHERE g.code = 'milk' AND c.name = 'Specialty Coffee'
    ''');
    expect(rows, isEmpty);
  });

  test('the drinks that are made with milk still ask', () async {
    final List<Map<String, Object?>> rows = await db.db.rawQuery('''
      SELECT p.name FROM product_customization_groups pcg
      JOIN products p ON p.id = pcg.product_id
      JOIN customization_groups g ON g.id = pcg.group_id
      WHERE g.code = 'milk' ORDER BY p.name
    ''');
    expect(rows.map((Map<String, Object?> r) => r['name']), <String>[
      'Caramel Macchiato',
      'Cinnamon Oat Latte',
      'Matcha Oat Latte',
      'Sea Salt Matcha Oat Latte',
      'Spanish Latte',
    ], reason: 'Iced Black and all three Vietnamese coffees take no milk');
  });
}
