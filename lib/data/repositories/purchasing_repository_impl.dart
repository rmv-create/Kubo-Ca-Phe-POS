import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import '../../core/money/money.dart';
import '../../core/money/unit_cost.dart';
import '../../core/quantity/measurement_unit.dart';
import '../../core/quantity/quantity.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/business_settings.dart';
import '../../domain/entities/ingredient.dart';
import '../../domain/entities/purchasing.dart';
import '../../domain/repositories/purchasing_repository.dart';
import '../../domain/services/inventory_engine.dart';
import '../db/app_database.dart';

class PurchasingRepositoryImpl implements PurchasingRepository {
  PurchasingRepositoryImpl(
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

  @override
  Future<List<Supplier>> suppliers({bool includeInactive = false}) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery('''
      SELECT s.*, COUNT(i.id) AS ingredient_count
      FROM suppliers s
      LEFT JOIN ingredients i ON i.default_supplier_id = s.id
      ${includeInactive ? '' : 'WHERE s.is_active = 1'}
      GROUP BY s.id
      ORDER BY s.name COLLATE NOCASE
      ''');
    return rows
        .map(
          (Map<String, Object?> r) => Supplier(
            id: r['id']! as int,
            name: r['name']! as String,
            contactPerson: r['contact_person'] as String?,
            contactDetails: r['contact_details'] as String?,
            notes: r['notes'] as String?,
            isActive: r['is_active'] == 1,
            ingredientCount: (r['ingredient_count'] as int?) ?? 0,
          ),
        )
        .toList();
  }

  @override
  Future<int> createSupplier({
    required String name,
    String? contactPerson,
    String? contactDetails,
    String? notes,
  }) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationException(
        'A supplier needs a name.',
        field: 'name',
      );
    }
    final String now = _clock.nowIso();
    try {
      return await _db.db.insert('suppliers', <String, Object?>{
        'name': trimmed,
        'contact_person': contactPerson?.trim(),
        'contact_details': contactDetails?.trim(),
        'notes': notes?.trim(),
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        throw ValidationException(
          'There is already a supplier called "$trimmed".',
          cause: e,
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> updateSupplier(Supplier supplier) async {
    await _db.db.update(
      'suppliers',
      <String, Object?>{
        'name': supplier.name.trim(),
        'contact_person': supplier.contactPerson?.trim(),
        'contact_details': supplier.contactDetails?.trim(),
        'notes': supplier.notes?.trim(),
        'is_active': supplier.isActive ? 1 : 0,
        'updated_at': _clock.nowIso(),
      },
      where: 'id = ?',
      whereArgs: <Object?>[supplier.id],
    );
  }

  /// Records a delivery.
  ///
  /// Three things happen together: stock goes up, the price paid is added to
  /// the ingredient's cost history, and the whole thing is audited. If any
  /// part fails none of it lands.
  @override
  Future<int> recordPurchase({
    int? supplierId,
    required List<PurchaseDraftLine> lines,
    String? notes,
  }) async {
    if (lines.isEmpty) {
      throw const ValidationException('Add at least one thing that came in.');
    }
    final String at = _clock.nowIso();
    final String date = BusinessDay(
      cutoffHour: _settings().businessDayCutoffHour,
    ).dateOf(_clock.now());

    return _db.transaction<int>((Transaction txn) async {
      int total = 0;
      final int purchaseId = await txn.insert('purchases', <String, Object?>{
        'supplier_id': supplierId,
        'purchased_at': at,
        'business_date': date,
        'total_centavos': 0,
        'notes': notes,
        'created_at': at,
      });

      final List<PendingMovement> movements = <PendingMovement>[];

      for (final PurchaseDraftLine line in lines) {
        final List<Map<String, Object?>> ingredientRow = await txn.query(
          'ingredients',
          columns: <String>['base_unit', 'purchase_unit_size_milli', 'name'],
          where: 'id = ?',
          whereArgs: <Object?>[line.ingredientId],
          limit: 1,
        );
        if (ingredientRow.isEmpty) {
          throw const NotFoundException('That ingredient no longer exists.');
        }
        final BaseUnit unit = BaseUnit.fromCode(
          ingredientRow.first['base_unit']! as String,
        );
        final int perUnit =
            ingredientRow.first['purchase_unit_size_milli']! as int;

        final Quantity quantity = Quantity(
          (line.quantityInPurchaseUnits * perUnit).round(),
          unit,
        );
        if (!quantity.isPositive) {
          throw const ValidationException('How much came in?');
        }

        // What this delivery actually cost per unit — the number future
        // drinks are costed at.
        final UnitCost unitCost = UnitCost(
          (line.totalCost.centavos * 1000000) ~/ quantity.milli,
          unit,
        );

        final int itemId = await txn.insert('purchase_items', <String, Object?>{
          'purchase_id': purchaseId,
          'ingredient_id': line.ingredientId,
          'qty_purchase_units': line.quantityInPurchaseUnits,
          'qty_milli': quantity.milli,
          'total_cost_centavos': line.totalCost.centavos,
          'unit_cost_centavos_per_1000_base': unitCost.centavosPer1000Base,
        });

        await txn.insert('ingredient_cost_history', <String, Object?>{
          'ingredient_id': line.ingredientId,
          'unit_cost_centavos_per_1000_base': unitCost.centavosPer1000Base,
          'effective_from': at,
          'source': 'purchase',
          'purchase_item_id': itemId,
          'created_at': at,
        });

        movements.add(
          PendingMovement(
            ingredientId: line.ingredientId,
            delta: quantity,
            type: MovementType.purchase,
            reason: 'Delivery',
            purchaseItemId: itemId,
            unitCost: unitCost,
          ),
        );
        total += line.totalCost.centavos;
      }

      await _engine.post(txn, movements, at: at, businessDate: date);

      await txn.update(
        'purchases',
        <String, Object?>{'total_centavos': total},
        where: 'id = ?',
        whereArgs: <Object?>[purchaseId],
      );

      await txn.insert('audit_log', <String, Object?>{
        'at': at,
        'business_date': date,
        'action': 'purchase_recorded',
        'entity_type': 'purchase',
        'entity_id': purchaseId,
        'summary':
            '${lines.length} item${lines.length == 1 ? '' : 's'} · '
            '${Money(total).format()}',
      });

      return purchaseId;
    });
  }

  @override
  Future<List<Purchase>> purchases({int limit = 50}) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT p.*, s.name AS supplier_name
      FROM purchases p
      LEFT JOIN suppliers s ON s.id = p.supplier_id
      ORDER BY p.purchased_at DESC, p.id DESC
      LIMIT ?
      ''',
      <Object?>[limit],
    );

    final List<Purchase> purchases = <Purchase>[];
    for (final Map<String, Object?> row in rows) {
      final int id = row['id']! as int;
      final List<Map<String, Object?>> lineRows = await _db.db.rawQuery(
        'SELECT pi.*, i.name AS ingredient_name, i.base_unit AS base_unit '
        'FROM purchase_items pi '
        'JOIN ingredients i ON i.id = pi.ingredient_id '
        'WHERE pi.purchase_id = ?',
        <Object?>[id],
      );
      purchases.add(
        Purchase(
          id: id,
          supplierId: row['supplier_id'] as int?,
          supplierName: row['supplier_name'] as String?,
          purchasedAt: DateTime.parse(row['purchased_at']! as String),
          businessDate: row['business_date']! as String,
          total: Money(row['total_centavos']! as int),
          notes: row['notes'] as String?,
          lines: lineRows
              .map(
                (Map<String, Object?> l) => PurchaseLine(
                  ingredientId: l['ingredient_id']! as int,
                  ingredientName: l['ingredient_name']! as String,
                  quantityInPurchaseUnits: (l['qty_purchase_units']! as num)
                      .toDouble(),
                  quantity: Quantity(
                    l['qty_milli']! as int,
                    BaseUnit.fromCode(l['base_unit']! as String),
                  ),
                  totalCost: Money(l['total_cost_centavos']! as int),
                ),
              )
              .toList(),
        ),
      );
    }
    return purchases;
  }
}
