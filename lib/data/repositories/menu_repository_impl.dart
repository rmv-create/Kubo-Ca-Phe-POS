import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import '../../core/money/money.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/menu.dart';
import '../../domain/repositories/menu_repository.dart';
import '../db/app_database.dart';

class MenuRepositoryImpl implements MenuRepository {
  MenuRepositoryImpl(this._db, this._clock);

  final AppDatabase _db;
  final Clock _clock;

  Map<String, Object?> _stamps({bool created = true}) {
    final String now = _clock.nowIso();
    return created
        ? <String, Object?>{'created_at': now, 'updated_at': now}
        : <String, Object?>{'updated_at': now};
  }

  // ─────────────────────────── whole menu ───────────────────────────

  @override
  Future<MenuSnapshot> loadMenu({bool includeInactive = false}) async {
    final List<ProductCategory> cats = await categories(
      includeInactive: includeInactive,
    );
    final List<DrinkSize> allSizes = await sizes(
      includeInactive: includeInactive,
    );
    final List<Product> allProducts = await products(
      includeArchived: includeInactive,
    );
    final List<CustomizationGroup> allGroups = await customizationGroups(
      includeInactive: includeInactive,
    );

    final Map<int, List<Product>> byCategory = <int, List<Product>>{
      for (final ProductCategory c in cats) c.id: <Product>[],
    };
    for (final Product p in allProducts) {
      byCategory.putIfAbsent(p.categoryId, () => <Product>[]).add(p);
    }

    return MenuSnapshot(
      categories: cats,
      sizes: allSizes,
      productsByCategory: byCategory,
      groups: allGroups,
    );
  }

  // ─────────────────────────── categories ───────────────────────────

  @override
  Future<List<ProductCategory>> categories({
    bool includeInactive = true,
  }) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'product_categories',
      where: includeInactive ? null : 'is_active = 1',
      orderBy: 'display_order, name COLLATE NOCASE',
    );
    return rows.map(_category).toList();
  }

  @override
  Future<int> createCategory({required String name}) async {
    final String trimmed = _requireText(name, 'Category name');
    final int order = await _nextOrder('product_categories');
    try {
      return await _db.db.insert('product_categories', <String, Object?>{
        'name': trimmed,
        'display_order': order,
        'is_active': 1,
        ..._stamps(),
      });
    } on DatabaseException catch (e) {
      throw _duplicate(e, 'A category called "$trimmed" already exists.');
    }
  }

  @override
  Future<void> updateCategory(ProductCategory category) async {
    final String trimmed = _requireText(category.name, 'Category name');
    try {
      await _db.db.update(
        'product_categories',
        <String, Object?>{
          'name': trimmed,
          'display_order': category.displayOrder,
          'is_active': category.isActive ? 1 : 0,
          ..._stamps(created: false),
        },
        where: 'id = ?',
        whereArgs: <Object?>[category.id],
      );
    } on DatabaseException catch (e) {
      throw _duplicate(e, 'A category called "$trimmed" already exists.');
    }
  }

  @override
  Future<void> reorderCategories(List<int> idsInOrder) =>
      _reorder('product_categories', idsInOrder);

  // ─────────────────────────────── sizes ───────────────────────────────

  @override
  Future<List<DrinkSize>> sizes({bool includeInactive = true}) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'sizes',
      where: includeInactive ? null : 'is_active = 1',
      orderBy: 'display_order, volume_oz',
    );
    return rows.map(_size).toList();
  }

  @override
  Future<int> createSize({
    required String code,
    required String name,
    required double volumeOz,
  }) async {
    final String trimmedName = _requireText(name, 'Size name');
    final String trimmedCode = _requireText(code, 'Size code').toLowerCase();
    if (volumeOz <= 0) {
      throw const ValidationException(
        'A size needs a volume in ounces.',
        field: 'volumeOz',
      );
    }
    final int order = await _nextOrder('sizes');
    try {
      return await _db.db.insert('sizes', <String, Object?>{
        'code': trimmedCode,
        'name': trimmedName,
        'volume_oz': volumeOz,
        'display_order': order,
        'is_active': 1,
        ..._stamps(),
      });
    } on DatabaseException catch (e) {
      throw _duplicate(e, 'A size with code "$trimmedCode" already exists.');
    }
  }

  @override
  Future<void> updateSize(DrinkSize size) async {
    if (size.volumeOz <= 0) {
      throw const ValidationException(
        'A size needs a volume in ounces.',
        field: 'volumeOz',
      );
    }
    await _db.db.update(
      'sizes',
      <String, Object?>{
        'name': _requireText(size.name, 'Size name'),
        'volume_oz': size.volumeOz,
        'display_order': size.displayOrder,
        'is_active': size.isActive ? 1 : 0,
        ..._stamps(created: false),
      },
      where: 'id = ?',
      whereArgs: <Object?>[size.id],
    );
  }

  @override
  Future<void> reorderSizes(List<int> idsInOrder) =>
      _reorder('sizes', idsInOrder);

  // ────────────────────────────── products ──────────────────────────────

  @override
  Future<List<Product>> products({bool includeArchived = false}) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'products',
      where: includeArchived ? null : 'is_archived = 0',
      orderBy: 'display_order, name COLLATE NOCASE',
    );
    if (rows.isEmpty) return <Product>[];

    final Map<int, DrinkSize> sizeById = <int, DrinkSize>{
      for (final DrinkSize s in await sizes()) s.id: s,
    };
    final List<Map<String, Object?>> sizeRows = await _db.db.query(
      'product_sizes',
    );

    final Map<int, List<ProductSize>> byProduct = <int, List<ProductSize>>{};
    for (final Map<String, Object?> row in sizeRows) {
      final DrinkSize? size = sizeById[row['size_id']! as int];
      if (size == null) continue;
      byProduct
          .putIfAbsent(row['product_id']! as int, () => <ProductSize>[])
          .add(_productSize(row, size));
    }
    for (final List<ProductSize> list in byProduct.values) {
      list.sort(
        (ProductSize a, ProductSize b) =>
            a.size.displayOrder.compareTo(b.size.displayOrder),
      );
    }

    return rows
        .map(
          (Map<String, Object?> row) => _product(
            row,
            byProduct[row['id']! as int] ?? const <ProductSize>[],
          ),
        )
        .toList();
  }

  @override
  Future<Product?> productById(int id) async {
    final List<Product> all = await products(includeArchived: true);
    for (final Product p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  @override
  Future<int> createProduct({
    required int categoryId,
    required String name,
    String? description,
  }) async {
    final String trimmed = _requireText(name, 'Drink name');
    final int order = await _nextOrder(
      'products',
      where: 'category_id = ?',
      whereArgs: <Object?>[categoryId],
    );
    try {
      return await _db.db.insert('products', <String, Object?>{
        'category_id': categoryId,
        'name': trimmed,
        'description': description?.trim(),
        'display_order': order,
        'is_active': 1,
        'is_archived': 0,
        ..._stamps(),
      });
    } on DatabaseException catch (e) {
      throw _duplicate(e, 'A drink called "$trimmed" already exists.');
    }
  }

  @override
  Future<void> updateProduct(Product product) async {
    final String trimmed = _requireText(product.name, 'Drink name');
    try {
      await _db.db.update(
        'products',
        <String, Object?>{
          'category_id': product.categoryId,
          'name': trimmed,
          'description': product.description?.trim(),
          'display_order': product.displayOrder,
          'is_active': product.isActive ? 1 : 0,
          'is_archived': product.isArchived ? 1 : 0,
          ..._stamps(created: false),
        },
        where: 'id = ?',
        whereArgs: <Object?>[product.id],
      );
    } on DatabaseException catch (e) {
      throw _duplicate(e, 'A drink called "$trimmed" already exists.');
    }
  }

  @override
  Future<void> reorderProducts(int categoryId, List<int> idsInOrder) =>
      _reorder('products', idsInOrder);

  @override
  Future<void> archiveProduct(int productId) => _setArchived(productId, true);

  @override
  Future<void> restoreProduct(int productId) => _setArchived(productId, false);

  Future<void> _setArchived(int productId, bool archived) async {
    await _db.db.update(
      'products',
      <String, Object?>{
        'is_archived': archived ? 1 : 0,
        // An archived drink also leaves the POS immediately.
        if (archived) 'is_active': 0,
        ..._stamps(created: false),
      },
      where: 'id = ?',
      whereArgs: <Object?>[productId],
    );
  }

  @override
  Future<void> setProductSize({
    required int productId,
    required int sizeId,
    required int priceCentavos,
    required bool isAvailable,
    required bool isDefaultSize,
  }) async {
    if (priceCentavos < 0) {
      throw const ValidationException(
        'A price cannot be negative.',
        field: 'price',
      );
    }
    await _db.transaction((Transaction txn) async {
      if (isDefaultSize) {
        // Exactly one default size per drink.
        await txn.update(
          'product_sizes',
          <String, Object?>{'is_default_size': 0},
          where: 'product_id = ?',
          whereArgs: <Object?>[productId],
        );
      }
      final int updated = await txn.update(
        'product_sizes',
        <String, Object?>{
          'price_centavos': priceCentavos,
          'is_available': isAvailable ? 1 : 0,
          'is_default_size': isDefaultSize ? 1 : 0,
          ..._stamps(created: false),
        },
        where: 'product_id = ? AND size_id = ?',
        whereArgs: <Object?>[productId, sizeId],
      );
      if (updated == 0) {
        await txn.insert('product_sizes', <String, Object?>{
          'product_id': productId,
          'size_id': sizeId,
          'price_centavos': priceCentavos,
          'is_available': isAvailable ? 1 : 0,
          'is_default_size': isDefaultSize ? 1 : 0,
          ..._stamps(),
        });
      }
    });
  }

  @override
  Future<void> removeProductSize({
    required int productId,
    required int sizeId,
  }) async {
    final List<Map<String, Object?>> sold = await _db.db.rawQuery(
      'SELECT 1 FROM order_items WHERE product_id = ? AND size_id = ? LIMIT 1',
      <Object?>[productId, sizeId],
    );
    if (sold.isNotEmpty) {
      throw const BusinessRuleException(
        'This size has already been sold, so it cannot be deleted. '
        'Mark it unavailable instead — past orders keep their record.',
      );
    }
    await _db.db.delete(
      'product_sizes',
      where: 'product_id = ? AND size_id = ?',
      whereArgs: <Object?>[productId, sizeId],
    );
  }

  // ─────────────────────────── customisations ───────────────────────────

  @override
  Future<List<CustomizationGroup>> customizationGroups({
    bool includeInactive = true,
  }) async {
    final List<Map<String, Object?>> groupRows = await _db.db.query(
      'customization_groups',
      where: includeInactive ? null : 'is_active = 1',
      orderBy: 'display_order, name COLLATE NOCASE',
    );
    if (groupRows.isEmpty) return <CustomizationGroup>[];

    final List<Map<String, Object?>> optionRows = await _db.db.query(
      'customization_options',
      where: includeInactive ? null : 'is_active = 1',
      orderBy: 'display_order, name COLLATE NOCASE',
    );
    final Map<int, List<CustomizationOption>> byGroup =
        <int, List<CustomizationOption>>{};
    for (final Map<String, Object?> row in optionRows) {
      byGroup
          .putIfAbsent(row['group_id']! as int, () => <CustomizationOption>[])
          .add(_option(row));
    }

    return groupRows
        .map(
          (Map<String, Object?> row) => _group(
            row,
            byGroup[row['id']! as int] ?? const <CustomizationOption>[],
          ),
        )
        .toList();
  }

  @override
  Future<int> createCustomizationGroup({
    required String code,
    required String name,
    required SelectionType selectionType,
    required bool isRequired,
    required bool isProactive,
    int minSelect = 0,
    int? maxSelect,
  }) async {
    final String trimmedName = _requireText(name, 'Group name');
    final String trimmedCode = _requireText(code, 'Group code').toLowerCase();
    final int order = await _nextOrder('customization_groups');
    try {
      return await _db.db.insert('customization_groups', <String, Object?>{
        'code': trimmedCode,
        'name': trimmedName,
        'selection_type': selectionType.code,
        'min_select': minSelect,
        'max_select': maxSelect,
        'is_required': isRequired ? 1 : 0,
        'is_proactive': isProactive ? 1 : 0,
        'display_order': order,
        'is_active': 1,
        ..._stamps(),
      });
    } on DatabaseException catch (e) {
      throw _duplicate(e, 'A group with code "$trimmedCode" already exists.');
    }
  }

  @override
  Future<void> updateCustomizationGroup(CustomizationGroup group) async {
    await _db.db.update(
      'customization_groups',
      <String, Object?>{
        'name': _requireText(group.name, 'Group name'),
        'selection_type': group.selectionType.code,
        'min_select': group.minSelect,
        'max_select': group.maxSelect,
        'is_required': group.isRequired ? 1 : 0,
        'is_proactive': group.isProactive ? 1 : 0,
        'display_order': group.displayOrder,
        'is_active': group.isActive ? 1 : 0,
        ..._stamps(created: false),
      },
      where: 'id = ?',
      whereArgs: <Object?>[group.id],
    );
  }

  @override
  Future<int> createCustomizationOption({
    required int groupId,
    required String name,
    required int priceDeltaCentavos,
    String? description,
  }) async {
    final String trimmed = _requireText(name, 'Choice name');
    final int order = await _nextOrder(
      'customization_options',
      where: 'group_id = ?',
      whereArgs: <Object?>[groupId],
    );
    try {
      return await _db.db.insert('customization_options', <String, Object?>{
        'group_id': groupId,
        'name': trimmed,
        'description': description?.trim(),
        'price_delta_centavos': priceDeltaCentavos,
        'display_order': order,
        'is_active': 1,
        ..._stamps(),
      });
    } on DatabaseException catch (e) {
      throw _duplicate(e, 'This group already has a choice called "$trimmed".');
    }
  }

  @override
  Future<void> updateCustomizationOption(CustomizationOption option) async {
    await _db.db.update(
      'customization_options',
      <String, Object?>{
        'name': _requireText(option.name, 'Choice name'),
        'description': option.description?.trim(),
        'price_delta_centavos': option.priceDelta.centavos,
        'display_order': option.displayOrder,
        'is_active': option.isActive ? 1 : 0,
        ..._stamps(created: false),
      },
      where: 'id = ?',
      whereArgs: <Object?>[option.id],
    );
  }

  @override
  Future<void> reorderCustomizationOptions(int groupId, List<int> idsInOrder) =>
      _reorder('customization_options', idsInOrder);

  // ────────────────────────── per-product rules ──────────────────────────

  @override
  Future<List<ProductCustomizationRule>> rulesFor(int productId) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'product_customization_groups',
      where: 'product_id = ?',
      whereArgs: <Object?>[productId],
      orderBy: 'display_order',
    );
    return rows.map(_rule).toList();
  }

  @override
  Future<void> setProductRule({
    required int productId,
    required int groupId,
    int? sizeId,
    required bool isVisible,
    bool? isRequiredOverride,
    bool? isProactiveOverride,
    int? displayOrder,
  }) async {
    final Map<String, Object?> values = <String, Object?>{
      'is_visible': isVisible ? 1 : 0,
      'is_required_override': isRequiredOverride == null
          ? null
          : (isRequiredOverride ? 1 : 0),
      'is_proactive_override': isProactiveOverride == null
          ? null
          : (isProactiveOverride ? 1 : 0),
      ..._stamps(created: false),
    };
    if (displayOrder != null) values['display_order'] = displayOrder;

    final int updated = await _db.db.update(
      'product_customization_groups',
      values,
      where:
          'product_id = ? AND group_id = ? AND '
          '${sizeId == null ? 'size_id IS NULL' : 'size_id = ?'}',
      whereArgs: <Object?>[productId, groupId, if (sizeId != null) sizeId],
    );
    if (updated == 0) {
      await _db.db.insert('product_customization_groups', <String, Object?>{
        'product_id': productId,
        'size_id': sizeId,
        'group_id': groupId,
        'display_order':
            displayOrder ??
            await _nextOrder(
              'product_customization_groups',
              where: 'product_id = ?',
              whereArgs: <Object?>[productId],
            ),
        ...values,
        ..._stamps(),
      });
    }
  }

  @override
  Future<void> removeProductRule({
    required int productId,
    required int groupId,
    int? sizeId,
  }) async {
    await _db.db.delete(
      'product_customization_groups',
      where:
          'product_id = ? AND group_id = ? AND '
          '${sizeId == null ? 'size_id IS NULL' : 'size_id = ?'}',
      whereArgs: <Object?>[productId, groupId, if (sizeId != null) sizeId],
    );
  }

  @override
  Future<Set<int>> defaultOptionIdsFor(int productId, {int? sizeId}) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'product_default_options',
      where:
          'product_id = ? AND (size_id IS NULL'
          '${sizeId == null ? '' : ' OR size_id = ?'})',
      whereArgs: <Object?>[productId, if (sizeId != null) sizeId],
    );
    return rows.map((Map<String, Object?> r) => r['option_id']! as int).toSet();
  }

  @override
  Future<void> setDefaultOption({
    required int productId,
    required int optionId,
    int? sizeId,
  }) async {
    await _db.transaction((Transaction txn) async {
      // A single-choice group can only have one default, so clear its siblings.
      final List<Map<String, Object?>> groupRow = await txn.rawQuery(
        'SELECT g.id AS gid, g.selection_type AS st '
        'FROM customization_options o '
        'JOIN customization_groups g ON g.id = o.group_id '
        'WHERE o.id = ?',
        <Object?>[optionId],
      );
      if (groupRow.isEmpty) {
        throw const NotFoundException('That choice no longer exists.');
      }
      if (groupRow.first['st'] == 'single') {
        await txn.rawDelete(
          'DELETE FROM product_default_options '
          'WHERE product_id = ? AND option_id IN ('
          '  SELECT id FROM customization_options WHERE group_id = ?'
          ') AND ${sizeId == null ? 'size_id IS NULL' : 'size_id = ?'}',
          <Object?>[
            productId,
            groupRow.first['gid'],
            if (sizeId != null) sizeId,
          ],
        );
      }
      await txn.insert('product_default_options', <String, Object?>{
        'product_id': productId,
        'size_id': sizeId,
        'option_id': optionId,
        ..._stamps(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  @override
  Future<void> clearDefaultOption({
    required int productId,
    required int optionId,
    int? sizeId,
  }) async {
    await _db.db.delete(
      'product_default_options',
      where:
          'product_id = ? AND option_id = ? AND '
          '${sizeId == null ? 'size_id IS NULL' : 'size_id = ?'}',
      whereArgs: <Object?>[productId, optionId, if (sizeId != null) sizeId],
    );
  }

  @override
  Future<List<ResolvedCustomizationGroup>> resolvedGroupsFor(
    int productId, {
    int? sizeId,
  }) async {
    final List<CustomizationGroup> allGroups = await customizationGroups(
      includeInactive: false,
    );
    final Map<int, CustomizationGroup> byId = <int, CustomizationGroup>{
      for (final CustomizationGroup g in allGroups) g.id: g,
    };
    final List<ProductCustomizationRule> rules = await rulesFor(productId);
    final Set<int> defaults = await defaultOptionIdsFor(
      productId,
      sizeId: sizeId,
    );

    // A size-specific rule wins over the "all sizes" rule for the same group.
    final Map<int, ProductCustomizationRule> chosen =
        <int, ProductCustomizationRule>{};
    for (final ProductCustomizationRule rule in rules) {
      if (rule.sizeId != null && rule.sizeId != sizeId) continue;
      final ProductCustomizationRule? existing = chosen[rule.groupId];
      if (existing == null ||
          (existing.sizeId == null && rule.sizeId != null)) {
        chosen[rule.groupId] = rule;
      }
    }

    final List<ResolvedCustomizationGroup> resolved =
        <ResolvedCustomizationGroup>[];
    for (final ProductCustomizationRule rule in chosen.values) {
      final CustomizationGroup? group = byId[rule.groupId];
      if (group == null) continue;
      resolved.add(
        ResolvedCustomizationGroup(
          group: group,
          isVisible: rule.isVisible,
          isRequired: rule.requiredFor(group),
          isProactive: rule.proactiveFor(group),
          displayOrder: rule.displayOrder,
          defaultOptionIds: defaults
              .where(
                (int id) =>
                    group.options.any((CustomizationOption o) => o.id == id),
              )
              .toSet(),
        ),
      );
    }
    resolved.sort(
      (ResolvedCustomizationGroup a, ResolvedCustomizationGroup b) =>
          a.displayOrder.compareTo(b.displayOrder),
    );
    return resolved;
  }

  // ─────────────────────────────── helpers ───────────────────────────────

  Future<int> _nextOrder(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      'SELECT MAX(display_order) AS m FROM $table'
      '${where == null ? '' : ' WHERE $where'}',
      whereArgs,
    );
    return ((rows.first['m'] as int?) ?? -1) + 1;
  }

  Future<void> _reorder(String table, List<int> idsInOrder) async {
    await _db.transaction((Transaction txn) async {
      for (int i = 0; i < idsInOrder.length; i++) {
        await txn.update(
          table,
          <String, Object?>{'display_order': i},
          where: 'id = ?',
          whereArgs: <Object?>[idsInOrder[i]],
        );
      }
    });
  }

  static String _requireText(String value, String label) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ValidationException('$label cannot be empty.', field: label);
    }
    return trimmed;
  }

  static AppException _duplicate(DatabaseException error, String message) =>
      error.isUniqueConstraintError()
      ? ValidationException(message, cause: error)
      : StorageException('That change could not be saved.', cause: error);

  // ─────────────────────────────── mapping ───────────────────────────────

  static bool _flag(Object? v) => v == 1;

  static ProductCategory _category(Map<String, Object?> r) => ProductCategory(
    id: r['id']! as int,
    name: r['name']! as String,
    displayOrder: r['display_order']! as int,
    isActive: _flag(r['is_active']),
  );

  static DrinkSize _size(Map<String, Object?> r) => DrinkSize(
    id: r['id']! as int,
    code: r['code']! as String,
    name: r['name']! as String,
    volumeOz: (r['volume_oz']! as num).toDouble(),
    displayOrder: r['display_order']! as int,
    isActive: _flag(r['is_active']),
  );

  static ProductSize _productSize(Map<String, Object?> r, DrinkSize size) =>
      ProductSize(
        id: r['id']! as int,
        productId: r['product_id']! as int,
        size: size,
        price: Money(r['price_centavos']! as int),
        isAvailable: _flag(r['is_available']),
        isDefaultSize: _flag(r['is_default_size']),
      );

  static Product _product(Map<String, Object?> r, List<ProductSize> sizes) =>
      Product(
        id: r['id']! as int,
        categoryId: r['category_id']! as int,
        name: r['name']! as String,
        description: r['description'] as String?,
        displayOrder: r['display_order']! as int,
        isActive: _flag(r['is_active']),
        isArchived: _flag(r['is_archived']),
        sizes: sizes,
      );

  static CustomizationGroup _group(
    Map<String, Object?> r,
    List<CustomizationOption> options,
  ) => CustomizationGroup(
    id: r['id']! as int,
    code: r['code']! as String,
    name: r['name']! as String,
    selectionType: SelectionType.fromCode(r['selection_type']! as String),
    minSelect: r['min_select']! as int,
    maxSelect: r['max_select'] as int?,
    isRequired: _flag(r['is_required']),
    isProactive: _flag(r['is_proactive']),
    displayOrder: r['display_order']! as int,
    isActive: _flag(r['is_active']),
    options: options,
  );

  static CustomizationOption _option(Map<String, Object?> r) =>
      CustomizationOption(
        id: r['id']! as int,
        groupId: r['group_id']! as int,
        name: r['name']! as String,
        description: r['description'] as String?,
        priceDelta: Money(r['price_delta_centavos']! as int),
        displayOrder: r['display_order']! as int,
        isActive: _flag(r['is_active']),
      );

  static ProductCustomizationRule _rule(Map<String, Object?> r) =>
      ProductCustomizationRule(
        id: r['id']! as int,
        productId: r['product_id']! as int,
        sizeId: r['size_id'] as int?,
        groupId: r['group_id']! as int,
        isVisible: _flag(r['is_visible']),
        displayOrder: r['display_order']! as int,
        isRequiredOverride: r['is_required_override'] == null
            ? null
            : _flag(r['is_required_override']),
        isProactiveOverride: r['is_proactive_override'] == null
            ? null
            : _flag(r['is_proactive_override']),
        minSelectOverride: r['min_select_override'] as int?,
        maxSelectOverride: r['max_select_override'] as int?,
      );
}
