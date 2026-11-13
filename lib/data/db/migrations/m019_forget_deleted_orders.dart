import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Recounts what each customer usually orders, from the orders that are
/// still there.
///
/// Voiding or deleting an order takes its drinks back out of the customer's
/// habits, so that picking a regular does not offer them a drink they never
/// had. That was added after her sister had already been practising, and
/// nothing went back to tidy up the orders deleted before it — a drink rung
/// up once by mistake was still being offered as somebody's usual.
///
/// So the counts are worked out again here, from the order lines that
/// survive, ignoring anything voided. A habit with nothing left behind it
/// is removed.
///
/// Counts are recomputed rather than the table being rebuilt, so a pattern
/// she pinned by hand as somebody's usual keeps its row — and its id, which
/// the customer points at — as long as it still has orders behind it.
class M019ForgetDeletedOrders extends Migration {
  const M019ForgetDeletedOrders();

  @override
  int get version => 19;

  @override
  String get name => 'forget_deleted_orders';

  /// The signature a pattern is stored under, rebuilt from an order line.
  ///
  /// Matches `orderSignature` in the app: the drink, the size, and the
  /// option ids in ascending order. The inner ORDER BY is what makes the
  /// list match — two of the same drink must not differ because the
  /// customisations came back in a different order.
  static const String _signature = '''
    'p' || oi.product_id || '|s' || oi.size_id || '|o' || COALESCE(
      (SELECT group_concat(picked.option_id)
       FROM (SELECT option_id FROM order_item_customizations
             WHERE order_item_id = oi.id AND option_id IS NOT NULL
             ORDER BY option_id) AS picked), '')
  ''';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await db.execute('''
      UPDATE customer_order_patterns
      SET occurrence_count = COALESCE((
            SELECT SUM(oi.quantity)
            FROM order_items oi
            JOIN orders o ON o.id = oi.order_id
            WHERE o.customer_id = customer_order_patterns.customer_id
              AND o.status != 'voided'
              AND oi.product_id IS NOT NULL
              AND oi.size_id IS NOT NULL
              AND ($_signature) = customer_order_patterns.signature
          ), 0)
    ''');

    // Nothing left behind it, so it is not a habit.
    await db.execute(
      'DELETE FROM customer_order_patterns WHERE occurrence_count <= 0',
    );
  }
}
