import 'package:sqflite_common/sqlite_api.dart';

/// Works out what the stock on the shelf cost, and keeps that answer current.
///
/// The rule is the one anybody would do on paper. You have six litres that
/// cost you ₱125 each and ten arrive at ₱115:
///
/// ```text
///   (6 × 125) + (10 × 115)     750 + 1150
///   ──────────────────────  =  ──────────  =  ₱118.75 a litre
///          6 + 10                  16
/// ```
///
/// Use five of the dear litres first and the same delivery lands differently,
/// because there is less dear milk left to average against:
///
/// ```text
///   (1 × 125) + (10 × 115)     125 + 1150
///   ──────────────────────  =  ──────────  =  ₱115.91 a litre
///          1 + 10                  11
/// ```
///
/// Only two things move the average: a delivery, and the owner typing a cost
/// in by hand. Selling a coffee does not — it takes stock off the shelf at
/// the average, which leaves the average where it was. Nor does wastage, nor
/// a stock count, nor a void putting a drink back: all of those change *how
/// much* is on the shelf, not *what it cost*.
///
/// The whole table is derived, so it is never edited in place and never sent
/// between tills. It is rebuilt from the deliveries and the stock ledger,
/// which means it also comes out right when a delivery arrives from the other
/// till out of order, or a backup is restored.
class MovingAverageCost {
  const MovingAverageCost();

  /// Recomputes the average for every ingredient.
  Future<void> rebuildAll(DatabaseExecutor db) async {
    final List<Map<String, Object?>> rows = await db.query(
      'ingredients',
      columns: <String>['id'],
    );
    for (final Map<String, Object?> row in rows) {
      await rebuild(db, ingredientId: row['id']! as int);
    }
  }

  /// Recomputes the average for one ingredient, from the beginning.
  ///
  /// Replaying rather than appending is deliberate: it is the only way a
  /// delivery that turns up late — recorded a day after it arrived, or synced
  /// from the other till — lands in the right place in the sequence.
  Future<void> rebuild(DatabaseExecutor db, {required int ingredientId}) async {
    final String now = DateTime.now().toUtc().toIso8601String();

    await db.delete(
      'ingredient_avg_cost',
      where: 'ingredient_id = ?',
      whereArgs: <Object?>[ingredientId],
    );

    final Map<int, int> qtyBefore = await _stockBeforeEachDelivery(
      db,
      ingredientId,
    );

    final List<_Event> events = await _events(db, ingredientId);
    if (events.isEmpty) return;

    int? average;
    for (final _Event event in events) {
      final int before = average ?? event.unitCost;

      if (event.purchaseItemId == null) {
        // A price typed in by hand, or the one the pantry was set up with.
        // It is a statement about what the stock is worth, so it replaces
        // the average rather than averaging into it.
        await _write(
          db,
          ingredientId: ingredientId,
          event: event,
          qtyBefore: 0,
          qtyAdded: 0,
          avgBefore: before,
          avgAfter: event.unitCost,
          now: now,
        );
        average = event.unitCost;
        continue;
      }

      // Stock already on the shelf, valued at what it cost. Below zero means
      // the shelf was oversold; there is nothing there to average against.
      final int onHand = (qtyBefore[event.purchaseItemId!] ?? 0).clamp(
        0,
        1 << 62,
      );
      final int added = event.qtyMilli;

      // Micro-centavos throughout: a cost held per 1000 base units times a
      // quantity held in milli-base-units is exactly millionths of a centavo,
      // so the division happens once, at the end.
      final int valueBefore = onHand * before;
      final int valueAdded = event.totalCostCentavos * 1000000;
      final int total = onHand + added;
      final int after = total <= 0
          ? event.unitCost
          : (valueBefore + valueAdded) ~/ total;

      await _write(
        db,
        ingredientId: ingredientId,
        event: event,
        qtyBefore: onHand,
        qtyAdded: added,
        avgBefore: before,
        avgAfter: after,
        now: now,
      );
      average = after;
    }
  }

  /// How much was on the shelf immediately before each delivery landed.
  ///
  /// Read from the stock ledger rather than from the number cached on the
  /// movement, so that a rebuilt ledger and a rebuilt average agree.
  Future<Map<int, int>> _stockBeforeEachDelivery(
    DatabaseExecutor db,
    int ingredientId,
  ) async {
    final List<Map<String, Object?>> movements = await db.query(
      'inventory_movements',
      columns: <String>['id', 'at', 'qty_milli_delta', 'purchase_item_id'],
      where: 'ingredient_id = ?',
      whereArgs: <Object?>[ingredientId],
      orderBy: 'at ASC, id ASC',
    );

    final Map<int, int> before = <int, int>{};
    int running = 0;
    for (final Map<String, Object?> m in movements) {
      final int? purchaseItemId = m['purchase_item_id'] as int?;
      if (purchaseItemId != null) before[purchaseItemId] = running;
      running += m['qty_milli_delta']! as int;
    }
    return before;
  }

  /// Every moment the average could have moved, oldest first.
  Future<List<_Event>> _events(DatabaseExecutor db, int ingredientId) async {
    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT p.purchased_at                        AS at,
             'purchase'                            AS source,
             1                                     AS rank,
             pi.id                                 AS purchase_item_id,
             pi.qty_milli                          AS qty_milli,
             pi.total_cost_centavos                AS total_cost,
             pi.unit_cost_centavos_per_1000_base   AS unit_cost,
             pi.id                                 AS tiebreak
      FROM purchase_items pi
      JOIN purchases p ON p.id = pi.purchase_id
      WHERE pi.ingredient_id = ?

      UNION ALL

      SELECT ch.effective_from                     AS at,
             ch.source                             AS source,
             CASE ch.source WHEN 'seed' THEN 0 ELSE 2 END AS rank,
             NULL                                  AS purchase_item_id,
             0                                     AS qty_milli,
             0                                     AS total_cost,
             ch.unit_cost_centavos_per_1000_base   AS unit_cost,
             ch.id                                 AS tiebreak
      FROM ingredient_cost_history ch
      WHERE ch.ingredient_id = ? AND ch.source IN ('manual', 'seed')

      -- Same instant, which happens on a fresh install: the price the pantry
      -- was set up with comes first, then deliveries, then anything typed in
      -- by hand, because a correction is the last word on what it cost.
      ORDER BY at ASC, rank ASC, tiebreak ASC
      ''',
      <Object?>[ingredientId, ingredientId],
    );

    return rows
        .map(
          (Map<String, Object?> r) => _Event(
            at: r['at']! as String,
            source: r['source']! as String,
            purchaseItemId: r['purchase_item_id'] as int?,
            qtyMilli: (r['qty_milli'] as int?) ?? 0,
            totalCostCentavos: (r['total_cost'] as int?) ?? 0,
            unitCost: (r['unit_cost'] as int?) ?? 0,
          ),
        )
        .toList();
  }

  Future<void> _write(
    DatabaseExecutor db, {
    required int ingredientId,
    required _Event event,
    required int qtyBefore,
    required int qtyAdded,
    required int avgBefore,
    required int avgAfter,
    required String now,
  }) async {
    await db.insert('ingredient_avg_cost', <String, Object?>{
      'ingredient_id': ingredientId,
      'effective_from': event.at,
      'source': event.source,
      'qty_before_milli': qtyBefore,
      'qty_added_milli': qtyAdded,
      'avg_before_centavos_per_1000_base': avgBefore,
      'avg_after_centavos_per_1000_base': avgAfter < 0 ? 0 : avgAfter,
      'purchase_item_id': event.purchaseItemId,
      'created_at': now,
    });
  }
}

class _Event {
  const _Event({
    required this.at,
    required this.source,
    required this.purchaseItemId,
    required this.qtyMilli,
    required this.totalCostCentavos,
    required this.unitCost,
  });

  final String at;
  final String source;
  final int? purchaseItemId;
  final int qtyMilli;
  final int totalCostCentavos;
  final int unitCost;
}
