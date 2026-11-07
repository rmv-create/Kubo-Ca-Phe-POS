import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// The menu card's own names and prices, confirmed by the owner.
///
/// Until now the app carried the provisional prices from her first worksheet.
/// She has since sent the card itself and said plainly that these are the
/// current ones, so they are applied here rather than left for her to retype
/// nine times.
///
/// Three rules hold throughout:
///
/// * **Nothing already sold moves.** Every order line carries its own name and
///   price snapshot, so a Vietnamese Coffee rung up last week still reads
///   "Vietnamese Coffee ₱139.00" on its receipt. This changes what the next
///   customer is charged, not what the last one was.
/// * **Nothing is duplicated.** Each drink is matched by name. If she has
///   already added one herself — she added the Cinnamon Oat Latte in the app
///   before this shipped — it is re-priced, not added a second time.
/// * **Nothing is invented.** Every figure and every word below is off her
///   spreadsheet. Two of its descriptions are visibly copied from the drink
///   above (the Cinnamon Oat Latte and the Sea Salt Matcha); they are carried
///   over as written rather than rewritten, and she can edit them in the app.
///
/// She can change any of it afterwards: Manage → Menu → Drinks → the drink →
/// Change price.
class M006MenuCardPrices extends Migration {
  const M006MenuCardPrices();

  @override
  int get version => 6;

  @override
  String get name => 'menu_card_prices';

  /// The drink whose customisation rules a newly added drink inherits.
  ///
  /// Copying her live wiring is deliberate: if she has since turned a group
  /// off or changed a default, a new latte should behave like the lattes she
  /// actually has, not like the ones this app shipped with.
  static const String _template = 'Spanish Latte';

  /// Every drink on the card, with the prices she confirmed.
  ///
  /// Frozen here on purpose. A migration must do the same thing in a year as
  /// it does today, so it carries its own copy of the data rather than
  /// reading the seed, which is free to move on. A test checks that a
  /// database migrated through this file ends up with the same menu as a
  /// freshly seeded one.
  static const List<_CardDrink> _card = <_CardDrink>[
    _CardDrink(
      name: 'Iced Black',
      wasCalled: 'Black',
      category: 'Classics',
      small: 10900,
      large: 12900,
      description: 'Phin-brewed coffee served black. Bold, smooth and clean.',
    ),
    _CardDrink(
      name: 'Spanish Latte',
      category: 'Classics',
      small: 11900,
      large: 13900,
      description:
          'Bold phin coffee with creamy milk and a touch of sweetness.',
    ),
    _CardDrink(
      name: 'Cinnamon Oat Latte',
      category: 'Classics',
      small: 12900,
      large: 14900,
      // Her sheet repeats the Spanish Latte's wording here. Kept as written.
      description:
          'Bold phin coffee with creamy milk and a touch of sweetness.',
      defaultMilk: 'Oat',
    ),
    _CardDrink(
      name: 'Caramel Macchiato',
      wasCalled: 'Caramel Macchiato with Cold Foam',
      category: 'Classics',
      small: 14900,
      large: 16900,
      description:
          'Smooth milk, bold coffee, and caramel with our signature cold '
          'foam.',
    ),
    _CardDrink(
      name: 'Matcha Oat Latte',
      category: 'Classics',
      small: 14900,
      large: 16900,
      description:
          'Vibrant matcha with creamy milk. Smooth, earthy and lightly sweet.',
      defaultMilk: 'Oat',
    ),
    _CardDrink(
      name: 'Sea Salt Matcha Oat Latte',
      category: 'Classics',
      small: 16900,
      large: 18900,
      // Her sheet repeats the Matcha Oat Latte's wording here too.
      description:
          'Vibrant matcha with creamy milk. Smooth, earthy and lightly sweet.',
      defaultMilk: 'Oat',
    ),
    _CardDrink(
      name: 'Ca Phe Sua Da',
      wasCalled: 'Vietnamese Coffee',
      category: 'Specialty Coffee',
      small: 12400,
      large: 14400,
      description:
          'Traditional phin coffee with sweetened condensed milk. Strong, '
          'bold and comforting.',
    ),
    _CardDrink(
      name: 'Ca Phe Muoi',
      wasCalled: 'Vietnamese Sea Salt Cream',
      category: 'Specialty Coffee',
      small: 12900,
      large: 14900,
      description:
          'Strong phin coffee with smooth sea salt cream. Rich, creamy and '
          'perfectly balanced.',
    ),
    _CardDrink(
      name: 'Ca Phe Trung',
      wasCalled: 'Vietnamese Egg Coffee',
      category: 'Specialty Coffee',
      small: 14900,
      large: 16900,
      description:
          'Classic Hanoi-style egg coffee. Creamy, velvety and deliciously '
          'indulgent.',
    ),
  ];

  @override
  Future<void> up(DatabaseExecutor db) async {
    // A database that has not been seeded yet gets the card straight from the
    // seed and needs nothing here.
    final List<Map<String, Object?>> any = await db.rawQuery(
      'SELECT 1 FROM products LIMIT 1',
    );
    if (any.isEmpty) return;

    final String now = DateTime.now().toUtc().toIso8601String();

    for (final _CardDrink drink in _card) {
      final int? renamed = await _idOf(db, drink.wasCalled);
      final int? existing = await _idOf(db, drink.name);

      int productId;
      if (existing != null) {
        productId = existing;
      } else if (renamed != null) {
        await db.update(
          'products',
          <String, Object?>{'name': drink.name, 'updated_at': now},
          where: 'id = ?',
          whereArgs: <Object?>[renamed],
        );
        productId = renamed;
      } else {
        productId = await _add(db, drink, now);
      }

      await db.update(
        'products',
        <String, Object?>{'description': drink.description, 'updated_at': now},
        where: 'id = ?',
        whereArgs: <Object?>[productId],
      );
      await _price(db, productId, 'Small', drink.small, now);
      await _price(db, productId, 'Grande', drink.large, now);
      if (drink.defaultMilk != null) {
        await _oatIsFree(db, productId, now);
      }
    }
  }

  Future<int?> _idOf(DatabaseExecutor db, String? name) async {
    if (name == null) return null;
    final List<Map<String, Object?>> rows = await db.query(
      'products',
      columns: <String>['id'],
      where: 'name = ? COLLATE NOCASE',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id']! as int;
  }

  /// Sets one size's price, leaving a size she has removed alone.
  Future<void> _price(
    DatabaseExecutor db,
    int productId,
    String sizeName,
    int centavos,
    String now,
  ) async {
    final List<Map<String, Object?>> size = await db.query(
      'sizes',
      columns: <String>['id'],
      where: 'name = ? COLLATE NOCASE',
      whereArgs: <Object?>[sizeName],
      limit: 1,
    );
    if (size.isEmpty) return;
    final int sizeId = size.first['id']! as int;

    final int changed = await db.update(
      'product_sizes',
      <String, Object?>{'price_centavos': centavos, 'updated_at': now},
      where: 'product_id = ? AND size_id = ?',
      whereArgs: <Object?>[productId, sizeId],
    );
    if (changed == 0) {
      await db.insert('product_sizes', <String, Object?>{
        'product_id': productId,
        'size_id': sizeId,
        'price_centavos': centavos,
        'is_available': 1,
        'is_default_size': 0,
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  /// A drink the app has never heard of, wired up like the lattes she has.
  Future<int> _add(DatabaseExecutor db, _CardDrink drink, String now) async {
    // If she has renamed or removed the heading this drink belongs under, it
    // is made again rather than the drink being filed under the wrong one —
    // and never at the cost of the app failing to open.
    final List<Map<String, Object?>> category = await db.query(
      'product_categories',
      columns: <String>['id'],
      where: 'name = ? COLLATE NOCASE',
      whereArgs: <Object?>[drink.category],
      limit: 1,
    );
    final List<Map<String, Object?>> lastCategory = await db.rawQuery(
      'SELECT IFNULL(MAX(display_order), -1) AS m FROM product_categories',
    );
    final int categoryId = category.isNotEmpty
        ? category.first['id']! as int
        : await db.insert('product_categories', <String, Object?>{
            'name': drink.category,
            'display_order': (lastCategory.first['m']! as int) + 1,
            'created_at': now,
            'updated_at': now,
          });

    final List<Map<String, Object?>> last = await db.rawQuery(
      'SELECT IFNULL(MAX(display_order), -1) AS m FROM products '
      'WHERE category_id = ?',
      <Object?>[categoryId],
    );

    final int productId = await db.insert('products', <String, Object?>{
      'category_id': categoryId,
      'name': drink.name,
      'description': drink.description,
      'display_order': (last.first['m']! as int) + 1,
      'is_active': 1,
      'is_archived': 0,
      'created_at': now,
      'updated_at': now,
    });

    final int? template = await _idOf(db, _template);
    if (template == null) return productId;

    // Which groups it offers, and in what order.
    await db.rawInsert(
      '''
      INSERT INTO product_customization_groups
        (product_id, size_id, group_id, is_visible, is_required_override,
         min_select_override, max_select_override, display_order,
         created_at, updated_at)
      SELECT ?, size_id, group_id, is_visible, is_required_override,
             min_select_override, max_select_override, display_order, ?, ?
      FROM product_customization_groups WHERE product_id = ?
      ''',
      <Object?>[productId, now, now, template],
    );

    // What it comes with — her defaults, except the milk, which the card
    // names in the drink's own title.
    await db.rawInsert(
      '''
      INSERT INTO product_default_options
        (product_id, size_id, option_id, created_at, updated_at)
      SELECT ?, pdo.size_id, pdo.option_id, ?, ?
      FROM product_default_options pdo
      JOIN customization_options co ON co.id = pdo.option_id
      JOIN customization_groups cg ON cg.id = co.group_id
      WHERE pdo.product_id = ? AND cg.code <> 'milk'
      ''',
      <Object?>[productId, now, now, template],
    );

    final int? milk = await _optionId(db, 'milk', drink.defaultMilk);
    if (milk != null) {
      await db.insert('product_default_options', <String, Object?>{
        'product_id': productId,
        'size_id': null,
        'option_id': milk,
        'created_at': now,
        'updated_at': now,
      });
    }

    return productId;
  }

  /// Oat costs ₱20 as an upgrade on a drink it is an upgrade to. On a drink
  /// called an oat latte it is simply what the drink is made of, so it is
  /// overridden to nothing — the same rule the Matcha Oat Latte already uses.
  Future<void> _oatIsFree(
    DatabaseExecutor db,
    int productId,
    String now,
  ) async {
    final int? oat = await _optionId(db, 'milk', 'Oat');
    if (oat == null) return;
    await db.insert('product_option_prices', <String, Object?>{
      'product_id': productId,
      'option_id': oat,
      'price_delta_centavos': 0,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<int?> _optionId(
    DatabaseExecutor db,
    String groupCode,
    String? optionName,
  ) async {
    if (optionName == null) return null;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT co.id FROM customization_options co
      JOIN customization_groups cg ON cg.id = co.group_id
      WHERE cg.code = ? AND co.name = ? COLLATE NOCASE LIMIT 1
      ''',
      <Object?>[groupCode, optionName],
    );
    return rows.isEmpty ? null : rows.first['id']! as int;
  }
}

/// One line of her menu card.
class _CardDrink {
  const _CardDrink({
    required this.name,
    required this.category,
    required this.small,
    required this.large,
    required this.description,
    this.wasCalled,
    this.defaultMilk,
  });

  final String name;

  /// What the app used to call it, when the card calls it something else.
  final String? wasCalled;

  final String category;

  /// Centavos, as confirmed by the owner from her card.
  final int small;
  final int large;

  final String description;

  /// Set on the drinks whose name says what milk they are made with.
  final String? defaultMilk;
}
