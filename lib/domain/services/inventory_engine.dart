import 'package:sqflite_common/sqlite_api.dart';

import '../../core/money/money.dart';
import '../../core/money/unit_cost.dart';
import '../../core/quantity/measurement_unit.dart';
import '../../core/quantity/quantity.dart';
import '../entities/ingredient.dart';

/// One stock change waiting to be posted.
class PendingMovement {
  const PendingMovement({
    required this.ingredientId,
    required this.delta,
    required this.type,
    this.reason,
    this.orderId,
    this.orderItemId,
    this.purchaseItemId,
    this.wasteId,
    this.stockCountId,
    this.unitCost,
    this.note,
  });

  final int ingredientId;

  /// Negative takes stock out, positive puts it in.
  final Quantity delta;

  final MovementType type;
  final String? reason;
  final int? orderId;
  final int? orderItemId;
  final int? purchaseItemId;
  final int? wasteId;
  final int? stockCountId;
  final UnitCost? unitCost;
  final String? note;
}

/// The only way stock ever changes.
///
/// Every change is written as a ledger entry carrying the balance before and
/// after, so the running total in `inventory` is a cache that can be rebuilt
/// from the ledger at any time — and so the owner can always see *why* a
/// number moved.
class InventoryEngine {
  const InventoryEngine();

  /// Posts [movements] inside an existing transaction.
  ///
  /// Ingredients the owner has marked as not tracked — ice made fresh each day
  /// — are skipped here. They are still costed; they are simply not counted.
  Future<void> post(
    Transaction txn,
    List<PendingMovement> movements, {
    required String at,
    required String businessDate,
  }) async {
    for (final PendingMovement movement in movements) {
      if (movement.delta.isZero) continue;

      final List<Map<String, Object?>> ingredientRow = await txn.query(
        'ingredients',
        columns: <String>['is_inventory_tracked', 'base_unit'],
        where: 'id = ?',
        whereArgs: <Object?>[movement.ingredientId],
        limit: 1,
      );
      if (ingredientRow.isEmpty) continue;
      if (ingredientRow.first['is_inventory_tracked'] != 1) continue;

      final BaseUnit unit = BaseUnit.fromCode(
        ingredientRow.first['base_unit']! as String,
      );

      final List<Map<String, Object?>> balanceRow = await txn.query(
        'inventory',
        columns: <String>['qty_milli'],
        where: 'ingredient_id = ?',
        whereArgs: <Object?>[movement.ingredientId],
        limit: 1,
      );
      final Quantity before = Quantity(
        (balanceRow.isEmpty ? 0 : balanceRow.first['qty_milli']! as int),
        unit,
      );
      final Quantity after = before + movement.delta;

      final UnitCost? cost = movement.unitCost;
      final Money value = cost == null
          ? Money.zero
          : moneyFromMicroCentavos(cost.costMicroCentavos(movement.delta.abs));

      await txn.insert('inventory_movements', <String, Object?>{
        'at': at,
        'business_date': businessDate,
        'ingredient_id': movement.ingredientId,
        'movement_type': movement.type.code,
        'qty_milli_delta': movement.delta.milli,
        'qty_before_milli': before.milli,
        'qty_after_milli': after.milli,
        'unit_cost_centavos_per_1000_base': cost?.centavosPer1000Base ?? 0,
        'value_centavos': value.centavos,
        'reason': movement.reason,
        'order_id': movement.orderId,
        'order_item_id': movement.orderItemId,
        'purchase_item_id': movement.purchaseItemId,
        'waste_id': movement.wasteId,
        'stock_count_id': movement.stockCountId,
        'note': movement.note,
      });

      await txn.insert('inventory', <String, Object?>{
        'ingredient_id': movement.ingredientId,
        'qty_milli': after.milli,
        'updated_at': at,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Recomputes every balance from the ledger.
  ///
  /// The ledger is the truth; `inventory` is a cache. If the two ever disagree
  /// — a bug, a restore from an older backup — this puts them back in step
  /// without anyone having to recount the shelves.
  Future<int> rebuildFromLedger(Transaction txn, {required String at}) async {
    final List<Map<String, Object?>> totals = await txn.rawQuery(
      'SELECT ingredient_id AS id, SUM(qty_milli_delta) AS total '
      'FROM inventory_movements GROUP BY ingredient_id',
    );
    int corrected = 0;
    for (final Map<String, Object?> row in totals) {
      final int id = row['id']! as int;
      final int total = (row['total'] as int?) ?? 0;
      final List<Map<String, Object?>> current = await txn.query(
        'inventory',
        columns: <String>['qty_milli'],
        where: 'ingredient_id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      final int cached = current.isEmpty
          ? 0
          : current.first['qty_milli']! as int;
      if (cached == total) continue;
      await txn.insert('inventory', <String, Object?>{
        'ingredient_id': id,
        'qty_milli': total,
        'updated_at': at,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      corrected++;
    }
    return corrected;
  }
}
