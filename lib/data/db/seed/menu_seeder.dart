import 'package:sqflite_common/sqlite_api.dart';

import '../../../core/time/clock.dart';
import '../../../domain/entities/business_settings.dart';
import '../../../domain/entities/menu.dart';
import '../app_database.dart';
import 'menu_seed.dart';

/// Writes [MenuSeed] into an empty database, once.
///
/// Runs in a single transaction: either the whole menu lands or none of it
/// does. It refuses to run a second time, and refuses to run at all if any
/// product already exists — the owner's edits must never be overwritten by a
/// seed on a later launch.
class MenuSeeder {
  const MenuSeeder(this._db, this._clock);

  final AppDatabase _db;
  final Clock _clock;

  /// Returns true if it seeded, false if there was already a menu.
  Future<bool> seedIfEmpty() async {
    final List<Map<String, Object?>> existing = await _db.db.rawQuery(
      'SELECT 1 FROM products LIMIT 1',
    );
    if (existing.isNotEmpty) return false;

    final List<Map<String, Object?>> marker = await _db.db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: <Object?>[SettingKeys.menuSeeded],
      limit: 1,
    );
    if (marker.isNotEmpty) return false;

    await _db.transaction(_seed);
    return true;
  }

  Future<void> _seed(Transaction txn) async {
    final String now = _clock.nowIso();
    Map<String, Object?> stamps() => <String, Object?>{
      'created_at': now,
      'updated_at': now,
    };

    // ── categories ──
    final Map<String, int> categoryIds = <String, int>{};
    int order = 0;
    for (final String name in <String>[MenuSeed.classics, MenuSeed.specialty]) {
      categoryIds[name] = await txn.insert(
        'product_categories',
        <String, Object?>{
          'name': name,
          'display_order': order++,
          'is_active': 1,
          ...stamps(),
        },
      );
    }

    // ── sizes ──
    final Map<String, int> sizeIds = <String, int>{};
    order = 0;
    for (final SeedSize size in MenuSeed.sizes) {
      sizeIds[size.code] = await txn.insert('sizes', <String, Object?>{
        'code': size.code,
        'name': size.name,
        'volume_oz': size.volumeOz,
        'display_order': order++,
        'is_active': 1,
        ...stamps(),
      });
    }

    // ── customisation groups and their choices ──
    final Map<String, int> groupIds = <String, int>{};
    final Map<String, int> optionIds = <String, int>{}; // 'group/option' -> id
    final Map<String, List<String>> groupDefaults = <String, List<String>>{};
    order = 0;
    for (final SeedGroup group in MenuSeed.groups) {
      final int groupId = await txn
          .insert('customization_groups', <String, Object?>{
            'code': group.code,
            'name': group.name,
            'selection_type': group.selection.code,
            'min_select': 0,
            'max_select': group.selection == SelectionType.single ? 1 : null,
            'is_required': group.isRequired ? 1 : 0,
            'is_proactive': group.isProactive ? 1 : 0,
            'display_order': order++,
            'is_active': 1,
            ...stamps(),
          });
      groupIds[group.code] = groupId;

      int optionOrder = 0;
      for (final SeedOption option in group.options) {
        final int optionId = await txn
            .insert('customization_options', <String, Object?>{
              'group_id': groupId,
              'name': option.name,
              'description': option.needsPrice ? 'Price not set yet' : null,
              'price_delta_centavos': option.price,
              'display_order': optionOrder++,
              'is_active': option.isActive ? 1 : 0,
              ...stamps(),
            });
        optionIds['${group.code}/${option.name}'] = optionId;
        if (option.isDefault) {
          groupDefaults
              .putIfAbsent(group.code, () => <String>[])
              .add('${group.code}/${option.name}');
        }
      }
    }

    // ── drinks, their prices, their rules and their defaults ──
    final Map<String, int> productOrder = <String, int>{};
    final Map<String, int> productIds = <String, int>{};
    for (final SeedProduct product in MenuSeed.products) {
      final int categoryId = categoryIds[product.category]!;
      final int displayOrder = productOrder[product.category] ?? 0;
      productOrder[product.category] = displayOrder + 1;

      final int productId = await txn.insert('products', <String, Object?>{
        'category_id': categoryId,
        'name': product.name,
        'description': product.description,
        'display_order': displayOrder,
        'is_active': 1,
        'is_archived': 0,
        ...stamps(),
      });
      productIds[product.name] = productId;

      for (final SeedSize size in MenuSeed.sizes) {
        final int price = size.code == 'small'
            ? product.smallPrice
            : product.largePrice;
        await txn.insert('product_sizes', <String, Object?>{
          'product_id': productId,
          'size_id': sizeIds[size.code],
          'price_centavos': price,
          'is_available': 1,
          'is_default_size': size.code == product.defaultSizeCode ? 1 : 0,
          ...stamps(),
        });
      }

      int ruleOrder = 0;
      for (final SeedGroup group in MenuSeed.groups) {
        // Iced Black and Ca Phe Sua Da take no milk choice at all.
        if (group.code == 'milk' && !product.showsMilk) continue;

        await txn.insert('product_customization_groups', <String, Object?>{
          'product_id': productId,
          'size_id': null,
          'group_id': groupIds[group.code],
          'is_visible': group.isVisible ? 1 : 0,
          'is_required_override': null,
          'is_proactive_override': null,
          'display_order': ruleOrder++,
          ...stamps(),
        });

        // A drink can name its own milk; otherwise the group's default stands.
        final List<String> defaults =
            group.code == 'milk' && product.defaultMilk != null
            ? <String>['milk/${product.defaultMilk}']
            : (groupDefaults[group.code] ?? <String>[]);

        for (final String key in defaults) {
          final int? optionId = optionIds[key];
          if (optionId == null) continue;
          await txn.insert('product_default_options', <String, Object?>{
            'product_id': productId,
            'size_id': null,
            'option_id': optionId,
            ...stamps(),
          });
        }
      }
    }

    // ── options priced differently on one drink ──
    for (final SeedOptionPrice override in MenuSeed.optionPriceOverrides) {
      final int? productId = productIds[override.productName];
      final int? optionId =
          optionIds['${override.groupCode}/${override.optionName}'];
      if (productId == null || optionId == null) continue;
      await txn.insert('product_option_prices', <String, Object?>{
        'product_id': productId,
        'option_id': optionId,
        'price_delta_centavos': override.price,
        ...stamps(),
      });
    }

    // ── settings taken from the worksheet ──
    Future<void> put(String key, String value) => txn.insert(
      'app_settings',
      <String, Object?>{'key': key, 'value': value, 'updated_at': now},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await put(SettingKeys.menuSeeded, '1');
    // Her sheet: "prices and cost are not decided yet, I've put tentative
    // price". The app says so on screen until she confirms them.
    await put(SettingKeys.pricesProvisional, '1');
    await put(SettingKeys.orderNumberPrefix, 'KUBO');
    await put(SettingKeys.orderNumberStart, '1001');
    await put(SettingKeys.orderNumberResetDaily, '0');
    await put(SettingKeys.showCustomerName, '1');
  }

  /// Puts back anything from [MenuSeed] that this phone is missing.
  ///
  /// [seedIfEmpty] is all-or-nothing: one drink in the table and it leaves
  /// well alone, which is right when the shop is hers and wrong when the
  /// shop arrived in pieces. A phone that signed in while the owner's till
  /// had only pushed part of the menu ended up with four drinks of six and
  /// one size of two, and nothing would ever have fixed it, because from
  /// then on the table was not empty.
  ///
  /// So this fills the gaps instead of refusing to look. It only ever adds:
  /// a drink the phone does not have at all, a size missing from a drink it
  /// does, the groups and defaults that go with a drink it adds. Nothing
  /// already on the phone is touched — not a price she changed, not a drink
  /// she archived, not a size she turned off. Archiving is how a drink is
  /// taken off the menu, and an archived drink is still a row, so this
  /// cannot bring one back.
  ///
  /// Returns how many things it added, which is zero on a healthy phone.
  Future<int> repairMissing() async {
    int added = 0;
    await _db.transaction((Transaction txn) async {
      added = await _repair(txn);
    });
    return added;
  }

  Future<int> _repair(Transaction txn) async {
    final String now = _clock.nowIso();
    Map<String, Object?> stamps() => <String, Object?>{
      'created_at': now,
      'updated_at': now,
    };
    int added = 0;

    Future<int?> idOf(String table, String column, Object value) async {
      final List<Map<String, Object?>> rows = await txn.query(
        table,
        columns: <String>['id'],
        where: '$column = ?',
        whereArgs: <Object?>[value],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.first['id']! as int;
    }

    // ── categories ──
    final Map<String, int> categoryIds = <String, int>{};
    int order = 0;
    for (final String name in <String>[MenuSeed.classics, MenuSeed.specialty]) {
      int? id = await idOf('product_categories', 'name', name);
      if (id == null) {
        id = await txn.insert('product_categories', <String, Object?>{
          'name': name,
          'display_order': order,
          'is_active': 1,
          ...stamps(),
        });
        added++;
      }
      categoryIds[name] = id;
      order++;
    }

    // ── sizes ──
    final Map<String, int> sizeIds = <String, int>{};
    order = 0;
    for (final SeedSize size in MenuSeed.sizes) {
      int? id = await idOf('sizes', 'code', size.code);
      if (id == null) {
        id = await txn.insert('sizes', <String, Object?>{
          'code': size.code,
          'name': size.name,
          'volume_oz': size.volumeOz,
          'display_order': order,
          'is_active': 1,
          ...stamps(),
        });
        added++;
      }
      sizeIds[size.code] = id;
      order++;
    }

    // ── groups and their choices ──
    final Map<String, int> groupIds = <String, int>{};
    final Map<String, int> optionIds = <String, int>{};
    final Map<String, List<String>> groupDefaults = <String, List<String>>{};
    order = 0;
    for (final SeedGroup group in MenuSeed.groups) {
      int? groupId = await idOf('customization_groups', 'code', group.code);
      if (groupId == null) {
        groupId = await txn.insert('customization_groups', <String, Object?>{
          'code': group.code,
          'name': group.name,
          'selection_type': group.selection.code,
          'min_select': 0,
          'max_select': group.selection == SelectionType.single ? 1 : null,
          'is_required': group.isRequired ? 1 : 0,
          'is_proactive': group.isProactive ? 1 : 0,
          'display_order': order,
          'is_active': 1,
          ...stamps(),
        });
        added++;
      }
      groupIds[group.code] = groupId;
      order++;

      int optionOrder = 0;
      for (final SeedOption option in group.options) {
        final List<Map<String, Object?>> found = await txn.query(
          'customization_options',
          columns: <String>['id'],
          where: 'group_id = ? AND name = ?',
          whereArgs: <Object?>[groupId, option.name],
          limit: 1,
        );
        int optionId;
        if (found.isEmpty) {
          optionId = await txn
              .insert('customization_options', <String, Object?>{
                'group_id': groupId,
                'name': option.name,
                'description': option.needsPrice ? 'Price not set yet' : null,
                'price_delta_centavos': option.price,
                'display_order': optionOrder,
                'is_active': option.isActive ? 1 : 0,
                ...stamps(),
              });
          added++;
        } else {
          optionId = found.first['id']! as int;
        }
        optionIds['${group.code}/${option.name}'] = optionId;
        optionOrder++;
        if (option.isDefault) {
          groupDefaults
              .putIfAbsent(group.code, () => <String>[])
              .add('${group.code}/${option.name}');
        }
      }
    }

    // ── the drinks themselves ──
    final Map<String, int> productOrder = <String, int>{};
    for (final SeedProduct product in MenuSeed.products) {
      final int displayOrder = productOrder[product.category] ?? 0;
      productOrder[product.category] = displayOrder + 1;

      int? productId = await idOf('products', 'name', product.name);
      final bool isNew = productId == null;

      if (productId == null) {
        productId = await txn.insert('products', <String, Object?>{
          'category_id': categoryIds[product.category],
          'name': product.name,
          'description': product.description,
          'display_order': displayOrder,
          'is_active': 1,
          'is_archived': 0,
          ...stamps(),
        });
        added++;
      }

      // A missing size is the other half of what went wrong: a drink with
      // only a Small, priced as though that were the whole menu.
      for (final SeedSize size in MenuSeed.sizes) {
        final List<Map<String, Object?>> have = await txn.query(
          'product_sizes',
          columns: <String>['id'],
          where: 'product_id = ? AND size_id = ?',
          whereArgs: <Object?>[productId, sizeIds[size.code]],
          limit: 1,
        );
        if (have.isNotEmpty) continue;

        await txn.insert('product_sizes', <String, Object?>{
          'product_id': productId,
          'size_id': sizeIds[size.code],
          'price_centavos': size.code == 'small'
              ? product.smallPrice
              : product.largePrice,
          'is_available': 1,
          'is_default_size': size.code == product.defaultSizeCode ? 1 : 0,
          ...stamps(),
        });
        added++;
      }

      // The rules only go on a drink this pass has just created. On a drink
      // that was already here they are hers to decide, and the milk she has
      // or has not been offered is not for a repair to argue with.
      if (!isNew) continue;

      int ruleOrder = 0;
      for (final SeedGroup group in MenuSeed.groups) {
        if (group.code == 'milk' && !product.showsMilk) continue;

        await txn.insert('product_customization_groups', <String, Object?>{
          'product_id': productId,
          'size_id': null,
          'group_id': groupIds[group.code],
          'is_visible': group.isVisible ? 1 : 0,
          'is_required_override': null,
          'is_proactive_override': null,
          'display_order': ruleOrder++,
          ...stamps(),
        });

        final List<String> defaults =
            group.code == 'milk' && product.defaultMilk != null
            ? <String>['milk/${product.defaultMilk}']
            : (groupDefaults[group.code] ?? <String>[]);

        for (final String key in defaults) {
          final int? optionId = optionIds[key];
          if (optionId == null) continue;
          await txn.insert('product_default_options', <String, Object?>{
            'product_id': productId,
            'size_id': null,
            'option_id': optionId,
            ...stamps(),
          });
        }
      }
    }

    return added;
  }
}
