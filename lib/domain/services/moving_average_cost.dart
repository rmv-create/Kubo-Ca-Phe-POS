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
  ///
  /// Three questions and one answer for the whole pantry, however many
  /// ingredients it holds. It used to be four questions per ingredient — a
  /// hundred errands to the database, every time anything arrived from the
  /// other till, which on a phone's browser is felt as the till freezing
  /// mid-order. The arithmetic below is the same arithmetic; only the number
  /// of errands has changed.
  Future<void> rebuildAll(DatabaseExecutor db) async {
    final String now = DateTime.now().toUtc().toIso8601String();

    final Map<int, List<_Event>> eventsPerIngredient = await _allEvents(db);
    if (eventsPerIngredient.isEmpty) {
      await db.delete('ingredient_avg_cost');
      return;
    }
    final Map<int, Map<int, int>> stockPerIngredient = await _allStockBefore(
      db,
    );

    final Batch batch = db.batch();
    batch.delete('ingredient_avg_cost');
    for (final MapEntry<int, List<_Event>> entry
        in eventsPerIngredient.entries) {
      for (final _Line line in _replay(
        entry.value,
        stockPerIngredient[entry.key] ?? const <int, int>{},
      )) {
        batch.insert(
          'ingredient_avg_cost',
          line.asRow(ingredientId: entry.key, now: now),
        );
      }
    }
    await batch.commit(noResult: true);
  }

  /// Every moment the average could have moved, for every ingredient.
  Future<Map<int, List<_Event>>> _allEvents(DatabaseExecutor db) async {
    final List<Map<String, Object?>> rows = await db.rawQuery(_eventsSql());
    final Map<int, List<_Event>> out = <int, List<_Event>>{};
    for (final Map<String, Object?> row in rows) {
      (out[row['ingredient_id']! as int] ??= <_Event>[]).add(_Event.from(row));
    }
    return out;
  }

  /// How much was on the shelf before each delivery, for every ingredient.
  Future<Map<int, Map<int, int>>> _allStockBefore(DatabaseExecutor db) async {
    final List<Map<String, Object?>> movements = await db.query(
      'inventory_movements',
      columns: <String>[
        'id',
        'ingredient_id',
        'at',
        'qty_milli_delta',
        'purchase_item_id',
      ],
      orderBy: 'ingredient_id ASC, at ASC, id ASC',
    );

    final Map<int, Map<int, int>> out = <int, Map<int, int>>{};
    final Map<int, int> running = <int, int>{};
    for (final Map<String, Object?> m in movements) {
      final int ingredientId = m['ingredient_id']! as int;
      final int? purchaseItemId = m['purchase_item_id'] as int?;
      if (purchaseItemId != null) {
        (out[ingredientId] ??= <int, int>{})[purchaseItemId] =
            running[ingredientId] ?? 0;
      }
      running[ingredientId] =
          (running[ingredientId] ?? 0) + (m['qty_milli_delta']! as int);
    }
    return out;
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

    final Batch batch = db.batch();
    for (final _Line line in _replay(events, qtyBefore)) {
      batch.insert(
        'ingredient_avg_cost',
        line.asRow(ingredientId: ingredientId, now: now),
      );
    }
    await batch.commit(noResult: true);
  }

  /// Replays one ingredient's history and says what each step leaves behind.
  ///
  /// Pure arithmetic, no database: the same sequence the doc comment above
  /// works through on paper.
  List<_Line> _replay(List<_Event> events, Map<int, int> qtyBefore) {
    final List<_Line> lines = <_Line>[];
    int? average;

    for (final _Event event in events) {
      final int before = average ?? event.unitCost;

      if (event.purchaseItemId == null) {
        // A price typed in by hand, or the one the pantry was set up with.
        // It is a statement about what the stock is worth, so it replaces
        // the average rather than averaging into it.
        lines.add(
          _Line(
            event: event,
            qtyBefore: 0,
            qtyAdded: 0,
            avgBefore: before,
            avgAfter: event.unitCost,
          ),
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

      lines.add(
        _Line(
          event: event,
          qtyBefore: onHand,
          qtyAdded: added,
          avgBefore: before,
          avgAfter: after,
        ),
      );
      average = after;
    }
    return lines;
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
      _eventsSql(forOne: true),
      <Object?>[ingredientId, ingredientId],
    );
    return rows.map(_Event.from).toList();
  }

  /// The same history either way: deliveries, and prices typed in by hand.
  ///
  /// Same instant, which happens on a fresh install: the price the pantry
  /// was set up with comes first, then deliveries, then anything typed in by
  /// hand, because a correction is the last word on what it cost.
  static String _eventsSql({bool forOne = false}) =>
      '''
      SELECT pi.ingredient_id                      AS ingredient_id,
             p.purchased_at                        AS at,
             'purchase'                            AS source,
             1                                     AS rank,
             pi.id                                 AS purchase_item_id,
             pi.qty_milli                          AS qty_milli,
             pi.total_cost_centavos                AS total_cost,
             pi.unit_cost_centavos_per_1000_base   AS unit_cost,
             pi.id                                 AS tiebreak
      FROM purchase_items pi
      JOIN purchases p ON p.id = pi.purchase_id
      ${forOne ? 'WHERE pi.ingredient_id = ?' : ''}

      UNION ALL

      SELECT ch.ingredient_id                      AS ingredient_id,
             ch.effective_from                     AS at,
             ch.source                             AS source,
             CASE ch.source WHEN 'seed' THEN 0 ELSE 2 END AS rank,
             NULL                                  AS purchase_item_id,
             0                                     AS qty_milli,
             0                                     AS total_cost,
             ch.unit_cost_centavos_per_1000_base   AS unit_cost,
             ch.id                                 AS tiebreak
      FROM ingredient_cost_history ch
      WHERE ${forOne ? 'ch.ingredient_id = ? AND ' : ''}
            ch.source IN ('manual', 'seed')

      ORDER BY at ASC, rank ASC, tiebreak ASC
      ''';
}

class _Event {
  factory _Event.from(Map<String, Object?> r) => _Event(
    at: r['at']! as String,
    source: r['source']! as String,
    purchaseItemId: r['purchase_item_id'] as int?,
    qtyMilli: (r['qty_milli'] as int?) ?? 0,
    totalCostCentavos: (r['total_cost'] as int?) ?? 0,
    unitCost: (r['unit_cost'] as int?) ?? 0,
  );

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

/// One line of the replay: what the average was, and what it became.
class _Line {
  const _Line({
    required this.event,
    required this.qtyBefore,
    required this.qtyAdded,
    required this.avgBefore,
    required this.avgAfter,
  });

  final _Event event;
  final int qtyBefore;
  final int qtyAdded;
  final int avgBefore;
  final int avgAfter;

  Map<String, Object?> asRow({
    required int ingredientId,
    required String now,
  }) => <String, Object?>{
    'ingredient_id': ingredientId,
    'effective_from': event.at,
    'source': event.source,
    'qty_before_milli': qtyBefore,
    'qty_added_milli': qtyAdded,
    'avg_before_centavos_per_1000_base': avgBefore,
    'avg_after_centavos_per_1000_base': avgAfter < 0 ? 0 : avgAfter,
    'purchase_item_id': event.purchaseItemId,
    'created_at': now,
  };
}
