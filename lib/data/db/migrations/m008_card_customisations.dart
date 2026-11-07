import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// "There's no syrup or sauces. Only these customizations here."
///
/// Her menu card lists four, and they are the whole list:
///
///     Sea Salt Cold Foam   ₱20
///     Sub Oat              ₱20
///     1g Matcha            ₱15
///     Additional Sweetener FREE
///
/// Sub Oat is the milk group, which already charges ₱20 for oat and nothing
/// on the drinks made with it. The sweetener is under Sweetness, now free and
/// named the way the card names it. Sea Salt Cold Foam and 1g Matcha are the
/// Extras. Syrup and Sauce were invented from a first-draft worksheet and go.
///
/// Nothing is deleted. A choice that is switched off stops being offered but
/// stays in the database, so a receipt reprinted from an order that carried
/// a Vanilla syrup still reads exactly as it was rung up.
class M008CardCustomisations extends Migration {
  const M008CardCustomisations();

  @override
  int get version => 8;

  @override
  String get name => 'card_customisations';

  /// Groups the card does not have.
  static const List<String> _retiredGroups = <String>['syrup', 'sauce'];

  /// Extras the card does not have.
  static const List<String> _retiredExtras = <String>[
    'Extra Shot',
    'Extra Syrup',
    'Extra Sauce',
    'Cold Foam',
  ];

  @override
  Future<void> up(DatabaseExecutor db) async {
    final List<Map<String, Object?>> products = await db.query(
      'products',
      columns: <String>['id'],
      limit: 1,
    );
    // A fresh database is seeded with the card's list already.
    if (products.isEmpty) return;

    final String now = DateTime.now().toUtc().toIso8601String();

    for (final String code in _retiredGroups) {
      final int? groupId = await _groupId(db, code);
      if (groupId == null) continue;

      await db.update(
        'customization_groups',
        <String, Object?>{'is_active': 0, 'updated_at': now},
        where: 'id = ?',
        whereArgs: <Object?>[groupId],
      );
      // Unhooked from every drink as well, so it cannot come back if the
      // group is ever switched on again for something else.
      await db.delete(
        'product_customization_groups',
        where: 'group_id = ?',
        whereArgs: <Object?>[groupId],
      );
      await db.rawDelete(
        'DELETE FROM product_default_options WHERE option_id IN '
        '(SELECT id FROM customization_options WHERE group_id = ?)',
        <Object?>[groupId],
      );
    }

    final int? extras = await _groupId(db, 'extras');
    if (extras != null) {
      // The card's name for it, kept on the same row so every order that
      // already carries it still points at something.
      await db.update(
        'customization_options',
        <String, Object?>{
          'name': 'Sea Salt Cold Foam',
          'price_delta_centavos': 2000,
          'is_active': 1,
          'updated_at': now,
        },
        where: 'group_id = ? AND name = ? COLLATE NOCASE',
        whereArgs: <Object?>[extras, 'Sea Salt Cream'],
      );
      for (final String name in _retiredExtras) {
        await db.update(
          'customization_options',
          <String, Object?>{'is_active': 0, 'updated_at': now},
          where: 'group_id = ? AND name = ? COLLATE NOCASE',
          whereArgs: <Object?>[extras, name],
        );
      }
      await _addOption(
        db,
        groupId: extras,
        name: '1g Matcha',
        price: 1500,
        now: now,
      );
    }

    final int? sweetness = await _groupId(db, 'sweetness');
    if (sweetness != null) {
      final int renamed = await db.update(
        'customization_options',
        <String, Object?>{
          'name': 'Additional Sweetener',
          'price_delta_centavos': 0,
          'is_active': 1,
          'updated_at': now,
        },
        where: 'group_id = ? AND name = ? COLLATE NOCASE',
        whereArgs: <Object?>[sweetness, 'Extra Sweet'],
      );
      if (renamed == 0) {
        await _addOption(
          db,
          groupId: sweetness,
          name: 'Additional Sweetener',
          price: 0,
          now: now,
        );
      }
    }
  }

  Future<int?> _groupId(DatabaseExecutor db, String code) async {
    final List<Map<String, Object?>> rows = await db.query(
      'customization_groups',
      columns: <String>['id'],
      where: 'code = ?',
      whereArgs: <Object?>[code],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id']! as int;
  }

  /// Adds a choice, unless one of that name is already there.
  Future<void> _addOption(
    DatabaseExecutor db, {
    required int groupId,
    required String name,
    required int price,
    required String now,
  }) async {
    final List<Map<String, Object?>> existing = await db.query(
      'customization_options',
      columns: <String>['id'],
      where: 'group_id = ? AND name = ? COLLATE NOCASE',
      whereArgs: <Object?>[groupId, name],
      limit: 1,
    );
    if (existing.isNotEmpty) return;

    final List<Map<String, Object?>> last = await db.rawQuery(
      'SELECT IFNULL(MAX(display_order), -1) AS m '
      'FROM customization_options WHERE group_id = ?',
      <Object?>[groupId],
    );
    await db.insert('customization_options', <String, Object?>{
      'group_id': groupId,
      'name': name,
      'price_delta_centavos': price,
      'display_order': (last.first['m']! as int) + 1,
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });
  }
}
