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
            : product.grandePrice;
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
        // Black and Vietnamese Coffee take no milk choice at all.
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
    await put(SettingKeys.orderNumberPrefix, 'K');
    await put(SettingKeys.orderNumberResetDaily, '0');
    await put(SettingKeys.showCustomerName, '1');
  }
}
