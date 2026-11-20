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
    final List<PendingMovement> real = <PendingMovement>[
      for (final PendingMovement m in movements)
        if (!m.delta.isZero) m,
    ];
    if (real.isEmpty) return;

    // Two questions and one answer, rather than four errands per ingredient.
    // A drink touches a dozen ingredients and an order touches several
    // drinks; on a phone's browser each errand is a message to the database
    // and back, and those messages are what she feels as the till thinking.
    final Set<int> ids = <int>{
      for (final PendingMovement m in real) m.ingredientId,
    };
    final String holes = List<String>.filled(ids.length, '?').join(',');

    final List<Map<String, Object?>> ingredientRows = await txn.rawQuery(
      'SELECT id, is_inventory_tracked, base_unit '
      'FROM ingredients WHERE id IN ($holes)',
      ids.toList(),
    );
    final Map<int, Map<String, Object?>> known = <int, Map<String, Object?>>{
      for (final Map<String, Object?> row in ingredientRows)
        row['id']! as int: row,
    };

    final List<Map<String, Object?>> balanceRows = await txn.rawQuery(
      'SELECT ingredient_id, qty_milli '
      'FROM inventory WHERE ingredient_id IN ($holes)',
      ids.toList(),
    );
    final Map<int, int> onHand = <int, int>{
      for (final Map<String, Object?> row in balanceRows)
        row['ingredient_id']! as int: row['qty_milli']! as int,
    };

    final Batch batch = txn.batch();
    bool anything = false;

    for (final PendingMovement movement in real) {
      final Map<String, Object?>? ingredient = known[movement.ingredientId];
      if (ingredient == null) continue;
      // Ingredients the owner has marked as not tracked — ice made fresh each
      // day — are skipped here. They are still costed; simply not counted.
      if (ingredient['is_inventory_tracked'] != 1) continue;

      final BaseUnit unit = BaseUnit.fromCode(
        ingredient['base_unit']! as String,
      );

      // Several movements can touch the same shelf in one order, so the
      // balance is carried forward in step, exactly as it would be if each
      // one were read back from the database in turn.
      final Quantity before = Quantity(
        onHand[movement.ingredientId] ?? 0,
        unit,
      );
      final Quantity after = before + movement.delta;
      onHand[movement.ingredientId] = after.milli;

      final UnitCost? cost = movement.unitCost;
      final Money value = cost == null
          ? Money.zero
          : moneyFromMicroCentavos(cost.costMicroCentavos(movement.delta.abs));

      batch.insert('inventory_movements', <String, Object?>{
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

      batch.insert('inventory', <String, Object?>{
        'ingredient_id': movement.ingredientId,
        'qty_milli': after.milli,
        'updated_at': at,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      anything = true;
    }

    // One errand for the whole order's worth of writing.
    if (anything) await batch.commit(noResult: true);
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
