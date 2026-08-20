import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import '../../core/money/money.dart';
import '../../core/time/clock.dart';
import '../../data/db/app_database.dart';
import '../entities/business_settings.dart';
import '../entities/reporting.dart';

/// Sums the day, the month, and how each drink is doing.
///
/// Voided orders are excluded from every total. Refunds are netted off rather
/// than erased, so a day that took ₱2,000 and gave ₱200 back reads as both,
/// not as ₱1,800 appearing from nowhere.
class ReportingService {
  const ReportingService({
    required AppDatabase database,
    required Clock clock,
    required BusinessSettings Function() settings,
  }) : _db = database,
       _clock = clock,
       _settings = settings;

  final AppDatabase _db;
  final Clock _clock;
  final BusinessSettings Function() _settings;

  String get today => BusinessDay(
    cutoffHour: _settings().businessDayCutoffHour,
  ).dateOf(_clock.now());

  String get thisMonth => today.substring(0, 7);

  Future<SalesSummary> forDay(String businessDate) => _summarise(
    // The clause is built per table, because some of these queries read
    // `orders` directly and others join to it as `o`.
    where: (String prefix) => '${prefix}business_date = ?',
    args: <Object?>[businessDate],
    label: businessDate,
  );

  /// [month] is `YYYY-MM`.
  Future<SalesSummary> forMonth(String month) => _summarise(
    where: (String prefix) => 'substr(${prefix}business_date, 1, 7) = ?',
    args: <Object?>[month],
    label: month,
  );

  Future<SalesSummary> _summarise({
    required String Function(String prefix) where,
    required List<Object?> args,
    required String label,
  }) async {
    final List<Map<String, Object?>> sales = await _db.db.rawQuery('''
      SELECT COUNT(*) AS orders,
             IFNULL(SUM(total_centavos), 0) AS revenue,
             IFNULL(SUM(cogs_centavos), 0) AS cogs,
             IFNULL(SUM(gross_profit_centavos), 0) AS profit,
             IFNULL(SUM(item_count), 0) AS drinks,
             IFNULL(SUM(refunded_centavos), 0) AS refunded
      FROM orders
      WHERE status = 'completed' AND ${where('')}
      ''', args);
    final Map<String, Object?> row = sales.first;

    final List<Map<String, Object?>> payments = await _db.db.rawQuery('''
      SELECT p.method AS method, IFNULL(SUM(p.amount_centavos), 0) AS total
      FROM payments p
      JOIN orders o ON o.id = p.order_id
      WHERE o.status = 'completed' AND ${where('o.')}
      GROUP BY p.method
      ''', args);
    int cash = 0;
    int gcash = 0;
    for (final Map<String, Object?> p in payments) {
      if (p['method'] == 'cash') {
        cash = p['total']! as int;
      } else {
        gcash = p['total']! as int;
      }
    }

    final List<Map<String, Object?>> wasteRows = await _db.db.rawQuery(
      'SELECT IFNULL(SUM(value_centavos), 0) AS total FROM waste '
      'WHERE ${where('')}',
      args,
    );
    final List<Map<String, Object?>> voidRows = await _db.db.rawQuery(
      'SELECT IFNULL(SUM(amount_centavos), 0) AS total '
      'FROM order_voids WHERE ${where('')}',
      args,
    );
    final List<Map<String, Object?>> uncosted = await _db.db.rawQuery('''
      SELECT COUNT(DISTINCT o.id) AS n
      FROM orders o
      JOIN order_items oi ON oi.order_id = o.id
      WHERE o.status = 'completed' AND oi.recipe_version_id IS NULL
        AND ${where('o.')}
      ''', args);

    return SalesSummary(
      label: label,
      orderCount: row['orders']! as int,
      drinkCount: row['drinks']! as int,
      revenue: Money(row['revenue']! as int),
      cash: Money(cash),
      gcash: Money(gcash),
      cogs: Money(row['cogs']! as int),
      grossProfit: Money(row['profit']! as int),
      waste: Money(wasteRows.first['total']! as int),
      refunds: Money(row['refunded']! as int),
      voids: Money(voidRows.first['total']! as int),
      uncostedOrders: uncosted.first['n']! as int,
    );
  }

  /// How each drink and size performed, best-selling first.
  Future<List<ProductPerformance>> productPerformance({
    String? businessDate,
    String? month,
    int limit = 100,
  }) async {
    final String where = businessDate != null
        ? 'o.business_date = ?'
        : month != null
        ? 'substr(o.business_date, 1, 7) = ?'
        : '1 = 1';
    final List<Object?> args = <Object?>[
      if (businessDate != null) businessDate else if (month != null) month,
    ];

    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT oi.product_name_snapshot AS product,
             oi.size_name_snapshot AS size,
             SUM(oi.quantity - oi.refunded_quantity) AS units,
             SUM(oi.line_total_centavos
                 - (oi.unit_price_centavos * oi.refunded_quantity))
               AS revenue,
             SUM(oi.line_cogs_centavos
                 - (CASE WHEN oi.quantity = 0 THEN 0
                    ELSE (oi.line_cogs_centavos / oi.quantity) END
                    * oi.refunded_quantity))
               AS cogs,
             SUM(CASE WHEN oi.recipe_version_id IS NULL THEN 1 ELSE 0 END)
               AS uncosted
      FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      WHERE o.status = 'completed' AND $where
      GROUP BY oi.product_name_snapshot, oi.size_name_snapshot
      HAVING units > 0
      ORDER BY units DESC
      LIMIT ?
      ''',
      <Object?>[...args, limit],
    );

    return rows
        .map(
          (Map<String, Object?> r) => ProductPerformance(
            productName: r['product']! as String,
            sizeName: r['size']! as String,
            unitsSold: (r['units'] as int?) ?? 0,
            revenue: Money((r['revenue'] as int?) ?? 0),
            cogs: Money((r['cogs'] as int?) ?? 0),
            isCosted: ((r['uncosted'] as int?) ?? 0) == 0,
          ),
        )
        .toList();
  }

  /// Same data, ranked by what it actually earns rather than what sells most.
  /// The two are rarely the same list, which is the point of showing both.
  Future<List<ProductPerformance>> mostProfitable({
    String? businessDate,
    String? month,
    int limit = 100,
  }) async {
    final List<ProductPerformance> all = await productPerformance(
      businessDate: businessDate,
      month: month,
      limit: limit,
    );
    return all.where((ProductPerformance p) => p.isCosted).toList()..sort(
      (ProductPerformance a, ProductPerformance b) =>
          b.grossProfit.compareTo(a.grossProfit),
    );
  }

  // ─────────────────────────── daily closing ───────────────────────────

  Future<DailyClosing?> closingFor(String businessDate) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'daily_closings',
      where: 'business_date = ?',
      whereArgs: <Object?>[businessDate],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final Map<String, Object?> r = rows.first;
    return DailyClosing(
      id: r['id']! as int,
      businessDate: businessDate,
      closedAt: DateTime.parse(r['closed_at']! as String),
      summary: SalesSummary(
        label: businessDate,
        orderCount: r['order_count']! as int,
        drinkCount: 0,
        revenue: Money(r['revenue_centavos']! as int),
        cash: Money(r['cash_centavos']! as int),
        gcash: Money(r['gcash_centavos']! as int),
        cogs: Money(r['cogs_centavos']! as int),
        grossProfit: Money(r['gross_profit_centavos']! as int),
        waste: Money(r['waste_centavos']! as int),
        refunds: Money(r['refunds_centavos']! as int),
        voids: Money(r['voids_centavos']! as int),
        uncostedOrders: 0,
      ),
    );
  }

  Future<List<DailyClosing>> recentClosings({int limit = 30}) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'daily_closings',
      orderBy: 'business_date DESC',
      limit: limit,
    );
    final List<DailyClosing> closings = <DailyClosing>[];
    for (final Map<String, Object?> r in rows) {
      final DailyClosing? c = await closingFor(r['business_date']! as String);
      if (c != null) closings.add(c);
    }
    return closings;
  }

  /// Locks in a day's figures.
  ///
  /// The totals are recomputed from the transactions at the moment of closing
  /// and stored, so the closed day is a statement of what was actually
  /// recorded rather than a query that could drift later.
  Future<DailyClosing> closeDay(String businessDate) async {
    final DailyClosing? existing = await closingFor(businessDate);
    if (existing != null) {
      throw BusinessRuleException('$businessDate has already been closed.');
    }

    final SalesSummary summary = await forDay(businessDate);
    final String at = _clock.nowIso();

    return _db.transaction<DailyClosing>((Transaction txn) async {
      final int id = await txn.insert('daily_closings', <String, Object?>{
        'business_date': businessDate,
        'closed_at': at,
        'order_count': summary.orderCount,
        'revenue_centavos': summary.revenue.centavos,
        'cash_centavos': summary.cash.centavos,
        'gcash_centavos': summary.gcash.centavos,
        'cogs_centavos': summary.cogs.centavos,
        'gross_profit_centavos': summary.grossProfit.centavos,
        'gross_margin_bp': summary.grossMarginBasisPoints ?? 0,
        'waste_centavos': summary.waste.centavos,
        'refunds_centavos': summary.refunds.centavos,
        'voids_centavos': summary.voids.centavos,
      });

      await txn.insert('audit_log', <String, Object?>{
        'at': at,
        'business_date': businessDate,
        'action': 'day_closed',
        'entity_type': 'daily_closing',
        'entity_id': id,
        'summary':
            '$businessDate · ${summary.orderCount} orders · '
            '${summary.revenue.format()}',
      });

      return DailyClosing(
        id: id,
        businessDate: businessDate,
        closedAt: DateTime.parse(at),
        summary: summary,
      );
    });
  }
}
