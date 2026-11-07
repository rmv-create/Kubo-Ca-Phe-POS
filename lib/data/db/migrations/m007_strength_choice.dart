import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// "There's option to customize the strength of coffee and matcha. If they
/// want it less strong."
///
/// A free choice of Less Strong, Regular or Extra Strong, offered on every
/// drink — every drink here is coffee or matcha. It sits with the other
/// quiet choices behind **More options**, so an ordinary order is still two
/// taps.
///
/// It does not change the recipe. A lighter cup is costed at what its recipe
/// says until she writes a recipe that says otherwise; the app would
/// otherwise be inventing a saving she has not measured.
class M007StrengthChoice extends Migration {
  const M007StrengthChoice();

  @override
  int get version => 7;

  @override
  String get name => 'strength_choice';

  static const List<String> _options = <String>[
    'Regular',
    'Less Strong',
    'Extra Strong',
  ];

  @override
  Future<void> up(DatabaseExecutor db) async {
    final List<Map<String, Object?>> products = await db.query(
      'products',
      columns: <String>['id'],
    );
    // A fresh database gets the group straight from the seed.
    if (products.isEmpty) return;

    final List<Map<String, Object?>> already = await db.query(
      'customization_groups',
      columns: <String>['id'],
      where: 'code = ?',
      whereArgs: <Object?>['strength'],
      limit: 1,
    );
    if (already.isNotEmpty) return;

    final String now = DateTime.now().toUtc().toIso8601String();
    final List<Map<String, Object?>> last = await db.rawQuery(
      'SELECT IFNULL(MAX(display_order), -1) AS m FROM customization_groups',
    );

    final int groupId = await db
        .insert('customization_groups', <String, Object?>{
          'code': 'strength',
          'name': 'Strength',
          'selection_type': 'single',
          'is_required': 0,
          'is_proactive': 0,
          'min_select': 0,
          'max_select': 1,
          'display_order': (last.first['m']! as int) + 1,
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        });

    for (int i = 0; i < _options.length; i++) {
      await db.insert('customization_options', <String, Object?>{
        'group_id': groupId,
        'name': _options[i],
        'price_delta_centavos': 0,
        'display_order': i,
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
    }

    for (final Map<String, Object?> product in products) {
      final List<Map<String, Object?>> order = await db.rawQuery(
        'SELECT IFNULL(MAX(display_order), -1) AS m '
        'FROM product_customization_groups WHERE product_id = ?',
        <Object?>[product['id']],
      );
      await db.insert('product_customization_groups', <String, Object?>{
        'product_id': product['id'],
        'size_id': null,
        'group_id': groupId,
        'is_visible': 1,
        'display_order': (order.first['m']! as int) + 1,
        'created_at': now,
        'updated_at': now,
      });
    }
  }
}
