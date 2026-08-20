import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import '../../core/money/money.dart';
import '../../core/money/unit_cost.dart';
import '../../core/quantity/measurement_unit.dart';
import '../../core/quantity/quantity.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/business_settings.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/repositories/inventory_repository.dart';
import '../../domain/services/costing_engine.dart';
import '../../domain/services/inventory_engine.dart';
import '../db/app_database.dart';

class InventoryRepositoryImpl implements InventoryRepository {
  InventoryRepositoryImpl(
    this._db,
    this._clock, {
    required BusinessSettings Function() settings,
    InventoryEngine engine = const InventoryEngine(),
  }) : _settings = settings,
       _engine = engine;

  final AppDatabase _db;
  final Clock _clock;
  final BusinessSettings Function() _settings;
  final InventoryEngine _engine;

  String get _businessDate => BusinessDay(
    cutoffHour: _settings().businessDayCutoffHour,
  ).dateOf(_clock.now());

  // ─────────────────────────── ingredients ───────────────────────────

  @override
  Future<List<Ingredient>> ingredients({
    bool includeInactive = false,
    bool withStockAndCost = true,
  }) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'ingredients',
      where: includeInactive ? null : 'is_active = 1',
      orderBy: 'category, name COLLATE NOCASE',
    );
    if (rows.isEmpty) return <Ingredient>[];

    Map<int, int> stock = <int, int>{};
    Map<int, int> costs = <int, int>{};
    if (withStockAndCost) {
      stock = await _stockBalances();
      costs = await _currentCosts();
    }

    return rows
        .map(
          (Map<String, Object?> r) => _ingredient(
            r,
            stockMilli: stock[r['id']],
            costPer1000: costs[r['id']],
          ),
        )
        .toList();
  }

  @override
  Future<Ingredient?> ingredientById(
    int id, {
    bool withStockAndCost = true,
  }) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'ingredients',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    if (!withStockAndCost) return _ingredient(rows.first);

    final Map<int, int> stock = await _stockBalances();
    final Map<int, int> costs = await _currentCosts();
    return _ingredient(
      rows.first,
      stockMilli: stock[id],
      costPer1000: costs[id],
    );
  }

  @override
  Future<int> createIngredient({
    required String name,
    required BaseUnit baseUnit,
    required String purchaseUnitCode,
    required String purchaseUnitLabel,
    required Quantity purchaseUnitSize,
    String? category,
    bool isInventoryTracked = true,
  }) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationException(
        'An ingredient needs a name.',
        field: 'name',
      );
    }
    if (!purchaseUnitSize.isPositive) {
      throw const ValidationException(
        'Say how much is in one — a 1 kg bag is 1000 g.',
        field: 'purchaseUnitSize',
      );
    }
    final String now = _clock.nowIso();
    try {
      return await _db.db.insert('ingredients', <String, Object?>{
        'name': trimmed,
        'category': category?.trim(),
        'base_unit': baseUnit.code,
        'purchase_unit_code': purchaseUnitCode,
        'purchase_unit_label': purchaseUnitLabel,
        'purchase_unit_size_milli': purchaseUnitSize.milli,
        'is_inventory_tracked': isInventoryTracked ? 1 : 0,
        'reorder_threshold_milli': 0,
        'critical_threshold_milli': 0,
        'target_stock_milli': 0,
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        throw ValidationException(
          'There is already an ingredient called "$trimmed".',
          cause: e,
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> updateIngredient(Ingredient ingredient) async {
    await _db.db.update(
      'ingredients',
      <String, Object?>{
        'name': ingredient.name.trim(),
        'category': ingredient.category?.trim(),
        'base_unit': ingredient.baseUnit.code,
        'purchase_unit_code': ingredient.purchaseUnitCode,
        'purchase_unit_label': ingredient.purchaseUnitLabel,
        'purchase_unit_size_milli': ingredient.purchaseUnitSize.milli,
        'is_inventory_tracked': ingredient.isInventoryTracked ? 1 : 0,
        'reorder_threshold_milli': ingredient.reorderThreshold.milli,
        'critical_threshold_milli': ingredient.criticalThreshold.milli,
        'target_stock_milli': ingredient.targetStock.milli,
        'default_supplier_id': ingredient.defaultSupplierId,
        'notes': ingredient.notes,
        'is_active': ingredient.isActive ? 1 : 0,
        'updated_at': _clock.nowIso(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[ingredient.id],
    );
  }

  // ────────────────────────────── costs ──────────────────────────────

  @override
  Future<void> recordCost({
    required int ingredientId,
    required UnitCost cost,
    String source = 'manual',
    String? note,
  }) async {
    final String now = _clock.nowIso();
    await _db.db.insert('ingredient_cost_history', <String, Object?>{
      'ingredient_id': ingredientId,
      'unit_cost_centavos_per_1000_base': cost.centavosPer1000Base,
      'effective_from': now,
      'source': source,
      'note': note,
      'created_at': now,
    });
  }

  @override
  Future<List<IngredientCost>> costHistory(int ingredientId) async {
    final List<Map<String, Object?>> unitRow = await _db.db.query(
      'ingredients',
      columns: <String>['base_unit'],
      where: 'id = ?',
      whereArgs: <Object?>[ingredientId],
      limit: 1,
    );
    if (unitRow.isEmpty) return <IngredientCost>[];
    final BaseUnit unit = BaseUnit.fromCode(
      unitRow.first['base_unit']! as String,
    );

    final List<Map<String, Object?>> rows = await _db.db.query(
      'ingredient_cost_history',
      where: 'ingredient_id = ?',
      whereArgs: <Object?>[ingredientId],
      orderBy: 'effective_from DESC, id DESC',
    );
    return rows
        .map(
          (Map<String, Object?> r) => IngredientCost(
            id: r['id']! as int,
            ingredientId: ingredientId,
            cost: UnitCost(r['unit_cost_centavos_per_1000_base']! as int, unit),
            effectiveFrom: DateTime.parse(r['effective_from']! as String),
            source: r['source']! as String,
            note: r['note'] as String?,
          ),
        )
        .toList();
  }

  // ───────────────────────────── alerts ─────────────────────────────

  @override
  Future<List<Ingredient>> stockAlerts() async {
    final List<Ingredient> all = await ingredients();
    final List<Ingredient> flagged =
        all.where((Ingredient i) => i.status.needsAttention).toList()
          ..sort((Ingredient a, Ingredient b) {
            // Critical first, then whichever is closest to running out.
            final int byStatus = a.status.index.compareTo(b.status.index);
            if (byStatus != 0) return byStatus;
            return (a.onHand?.milli ?? 0).compareTo(b.onHand?.milli ?? 0);
          });
    return flagged;
  }

  // ──────────────────────────── movements ────────────────────────────

  @override
  Future<List<InventoryMovement>> movements({
    int? ingredientId,
    String? businessDate,
    int limit = 100,
  }) async {
    final List<String> where = <String>[];
    final List<Object?> args = <Object?>[];
    if (ingredientId != null) {
      where.add('m.ingredient_id = ?');
      args.add(ingredientId);
    }
    if (businessDate != null) {
      where.add('m.business_date = ?');
      args.add(businessDate);
    }

    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT m.*, i.name AS ingredient_name, i.base_unit AS base_unit
      FROM inventory_movements m
      JOIN ingredients i ON i.id = m.ingredient_id
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY m.at DESC, m.id DESC
      LIMIT ?
      ''',
      <Object?>[...args, limit],
    );
    return rows.map(_movement).toList();
  }

  // ────────────────────────────── waste ──────────────────────────────

  @override
  Future<int> recordWaste({
    required int ingredientId,
    required Quantity quantity,
    required WasteReason reason,
    String? notes,
  }) async {
    if (!quantity.isPositive) {
      throw const ValidationException(
        'How much was wasted?',
        field: 'quantity',
      );
    }
    final String at = _clock.nowIso();
    final String date = _businessDate;

    return _db.transaction<int>((Transaction txn) async {
      final CostingEngine costing = CostingEngine(txn);
      final UnitCost? cost = await costing.costOfIngredient(
        ingredientId,
        method: _settings().costingMethod,
        asOf: _clock.now(),
      );
      final Money value = cost == null
          ? Money.zero
          : moneyFromMicroCentavos(cost.costMicroCentavos(quantity));

      final int wasteId = await txn.insert('waste', <String, Object?>{
        'at': at,
        'business_date': date,
        'ingredient_id': ingredientId,
        'qty_milli': quantity.milli,
        'reason': reason.code,
        'value_centavos': value.centavos,
        'notes': notes,
      });

      await _engine.post(
        txn,
        <PendingMovement>[
          PendingMovement(
            ingredientId: ingredientId,
            delta: -quantity,
            type: MovementType.waste,
            reason: reason.label,
            wasteId: wasteId,
            unitCost: cost,
            note: notes,
          ),
        ],
        at: at,
        businessDate: date,
      );

      await txn.insert('audit_log', <String, Object?>{
        'at': at,
        'business_date': date,
        'action': 'waste_recorded',
        'entity_type': 'waste',
        'entity_id': wasteId,
        'summary': '${quantity.format()} · ${reason.label} · ${value.format()}',
      });
      return wasteId;
    });
  }

  @override
  Future<List<WasteEntry>> waste({
    String? businessDate,
    int limit = 100,
  }) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT w.*, i.name AS ingredient_name, i.base_unit AS base_unit
      FROM waste w
      JOIN ingredients i ON i.id = w.ingredient_id
      ${businessDate == null ? '' : 'WHERE w.business_date = ?'}
      ORDER BY w.at DESC, w.id DESC
      LIMIT ?
      ''',
      <Object?>[if (businessDate != null) businessDate, limit],
    );
    return rows
        .map(
          (Map<String, Object?> r) => WasteEntry(
            id: r['id']! as int,
            at: DateTime.parse(r['at']! as String),
            businessDate: r['business_date']! as String,
            ingredientId: r['ingredient_id']! as int,
            ingredientName: r['ingredient_name']! as String,
            quantity: Quantity(
              r['qty_milli']! as int,
              BaseUnit.fromCode(r['base_unit']! as String),
            ),
            reason: WasteReason.fromCode(r['reason']! as String),
            value: Money(r['value_centavos']! as int),
            notes: r['notes'] as String?,
          ),
        )
        .toList();
  }

  // ─────────────────────────── stock counts ───────────────────────────

  @override
  Future<List<StockVariance>> expectedAgainst(
    Map<int, Quantity> counted,
  ) async {
    final List<Ingredient> all = await ingredients();
    final List<StockVariance> variances = <StockVariance>[];
    for (final MapEntry<int, Quantity> entry in counted.entries) {
      final Ingredient? ingredient = all
          .where((Ingredient i) => i.id == entry.key)
          .firstOrNull;
      if (ingredient == null) continue;
      variances.add(
        StockVariance(
          ingredient: ingredient,
          expected: ingredient.onHand ?? Quantity.zero(ingredient.baseUnit),
          actual: entry.value,
        ),
      );
    }
    return variances;
  }

  @override
  Future<int> applyStockCount({
    required Map<int, Quantity> counted,
    String? note,
  }) async {
    final List<StockVariance> variances = await expectedAgainst(counted);
    final List<StockVariance> changed = variances
        .where((StockVariance v) => !v.matches)
        .toList();
    if (changed.isEmpty) return 0;

    final String at = _clock.nowIso();
    final String date = _businessDate;

    return _db.transaction<int>((Transaction txn) async {
      final int countId = await txn.insert('stock_counts', <String, Object?>{
        'counted_at': at,
        'business_date': date,
        'is_applied': 1,
        'applied_at': at,
        'note': note,
      });

      final CostingEngine costing = CostingEngine(txn);
      final List<PendingMovement> movements = <PendingMovement>[];
      for (final StockVariance v in variances) {
        await txn.insert('stock_count_items', <String, Object?>{
          'stock_count_id': countId,
          'ingredient_id': v.ingredient.id,
          'expected_milli': v.expected.milli,
          'actual_milli': v.actual.milli,
          'variance_milli': v.variance.milli,
        });
        if (v.matches) continue;
        movements.add(
          PendingMovement(
            ingredientId: v.ingredient.id,
            delta: v.variance,
            type: MovementType.adjustment,
            reason: 'Stock count',
            stockCountId: countId,
            unitCost: await costing.costOfIngredient(
              v.ingredient.id,
              method: _settings().costingMethod,
              asOf: _clock.now(),
            ),
          ),
        );
      }

      await _engine.post(txn, movements, at: at, businessDate: date);

      await txn.insert('audit_log', <String, Object?>{
        'at': at,
        'business_date': date,
        'action': 'stock_count_applied',
        'entity_type': 'stock_count',
        'entity_id': countId,
        'summary':
            '${changed.length} '
            'ingredient${changed.length == 1 ? '' : 's'} adjusted',
      });
      return changed.length;
    });
  }

  @override
  Future<int> rebuildBalances() => _db.transaction<int>(
    (Transaction txn) => _engine.rebuildFromLedger(txn, at: _clock.nowIso()),
  );

  // ────────────────────────────── helpers ──────────────────────────────

  Future<Map<int, int>> _stockBalances() async {
    final List<Map<String, Object?>> rows = await _db.db.query('inventory');
    return <int, int>{
      for (final Map<String, Object?> r in rows)
        r['ingredient_id']! as int: r['qty_milli']! as int,
    };
  }

  /// The most recent cost for every ingredient, in one query.
  Future<Map<int, int>> _currentCosts() async {
    // Two prices can land in the same second — setting a price by hand and
    // then recording a delivery. The later row wins, so the tie is broken on
    // id, exactly as the costing engine does it.
    final List<Map<String, Object?>> rows = await _db.db.rawQuery('''
      SELECT h.ingredient_id AS id, h.unit_cost_centavos_per_1000_base AS cost
      FROM ingredient_cost_history h
      JOIN (
        SELECT ingredient_id, MAX(id) AS newest_id
        FROM ingredient_cost_history
        WHERE (ingredient_id, effective_from) IN (
          SELECT ingredient_id, MAX(effective_from)
          FROM ingredient_cost_history
          GROUP BY ingredient_id
        )
        GROUP BY ingredient_id
      ) newest
        ON newest.newest_id = h.id
    ''');
    return <int, int>{
      for (final Map<String, Object?> r in rows)
        r['id']! as int: r['cost']! as int,
    };
  }

  static Ingredient _ingredient(
    Map<String, Object?> r, {
    int? stockMilli,
    int? costPer1000,
  }) {
    final BaseUnit unit = BaseUnit.fromCode(r['base_unit']! as String);
    return Ingredient(
      id: r['id']! as int,
      name: r['name']! as String,
      category: r['category'] as String?,
      baseUnit: unit,
      purchaseUnitCode: r['purchase_unit_code']! as String,
      purchaseUnitLabel: r['purchase_unit_label']! as String,
      purchaseUnitSize: Quantity(r['purchase_unit_size_milli']! as int, unit),
      isInventoryTracked: r['is_inventory_tracked'] == 1,
      reorderThreshold: Quantity(r['reorder_threshold_milli']! as int, unit),
      criticalThreshold: Quantity(r['critical_threshold_milli']! as int, unit),
      targetStock: Quantity(r['target_stock_milli']! as int, unit),
      defaultSupplierId: r['default_supplier_id'] as int?,
      notes: r['notes'] as String?,
      isActive: r['is_active'] == 1,
      onHand: stockMilli == null ? null : Quantity(stockMilli, unit),
      currentCost: costPer1000 == null ? null : UnitCost(costPer1000, unit),
    );
  }

  static InventoryMovement _movement(Map<String, Object?> r) {
    final BaseUnit unit = BaseUnit.fromCode(r['base_unit']! as String);
    return InventoryMovement(
      id: r['id']! as int,
      at: DateTime.parse(r['at']! as String),
      businessDate: r['business_date']! as String,
      ingredientId: r['ingredient_id']! as int,
      ingredientName: r['ingredient_name']! as String,
      type: MovementType.fromCode(r['movement_type']! as String),
      delta: Quantity(r['qty_milli_delta']! as int, unit),
      before: Quantity(r['qty_before_milli']! as int, unit),
      after: Quantity(r['qty_after_milli']! as int, unit),
      value: Money(r['value_centavos']! as int),
      reason: r['reason'] as String?,
      orderId: r['order_id'] as int?,
      note: r['note'] as String?,
    );
  }
}
