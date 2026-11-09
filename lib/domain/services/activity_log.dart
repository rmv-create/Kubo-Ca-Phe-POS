import '../../data/db/app_database.dart';

/// Everything that has happened in the shop, in the order it happened.
///
/// The table has been filling up since the first version — orders, voids,
/// refunds, waste, deliveries, recipe changes, stock counts, days closed —
/// and until now nothing read it. It is the answer to "when did that
/// happen, and who did it", which is a question an owner starts asking the
/// day somebody else is allowed near the till.
class ActivityLog {
  const ActivityLog(this._db);

  final AppDatabase _db;

  Future<List<ActivityEntry>> recent({
    String? businessDate,
    int limit = 200,
  }) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'audit_log',
      where: businessDate == null ? null : 'business_date = ?',
      whereArgs: businessDate == null ? null : <Object?>[businessDate],
      orderBy: 'at DESC, id DESC',
      limit: limit,
    );
    return <ActivityEntry>[
      for (final Map<String, Object?> r in rows)
        ActivityEntry(
          at: DateTime.parse(r['at']! as String),
          businessDate: r['business_date']! as String,
          action: r['action']! as String,
          summary: r['summary']! as String,
          actor: r['actor'] as String?,
        ),
    ];
  }

  /// The days that have anything on them, newest first.
  Future<List<String>> days({int limit = 60}) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      'SELECT DISTINCT business_date AS d FROM audit_log '
      'ORDER BY d DESC LIMIT ?',
      <Object?>[limit],
    );
    return <String>[for (final Map<String, Object?> r in rows) r['d']! as String];
  }
}

class ActivityEntry {
  const ActivityEntry({
    required this.at,
    required this.businessDate,
    required this.action,
    required this.summary,
    this.actor,
  });

  final DateTime at;
  final String businessDate;
  final String action;
  final String summary;

  /// Who was signed in. Null for anything done before staff PINs were set
  /// up, and for anything the app did by itself.
  final String? actor;

  /// The action in words, and whether it is the kind of thing worth
  /// noticing. A void and a refund move money back out of the day; the
  /// rest are the shop working normally.
  String get label => switch (action) {
    'order_completed' => 'Order rung up',
    'order_voided' => 'Order voided',
    'refund_issued' => 'Refund given',
    'payment_recorded' => 'Payment received',
    'order_customer_attached' => 'Order put under a customer',
    'waste_recorded' => 'Waste recorded',
    'purchase_recorded' => 'Delivery recorded',
    'stock_count_applied' => 'Stock counted',
    'recipe_version_saved' => 'Recipe changed',
    'day_closed' => 'Day closed',
    _ => action.replaceAll('_', ' '),
  };

  bool get isNotable =>
      action == 'order_voided' ||
      action == 'refund_issued' ||
      action == 'recipe_version_saved' ||
      action == 'stock_count_applied';
}
