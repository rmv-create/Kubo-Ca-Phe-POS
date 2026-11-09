import '../../core/money/money.dart';
import '../../data/db/app_database.dart';

/// The month, read the way a shop owner reads it.
///
/// Everything here comes out of what she has already typed: orders, the
/// recipes behind them, the deliveries she recorded, the spills she owned
/// up to. Nothing new to key in, and no number invented.
///
/// One thing it deliberately does not claim to be is a full income
/// statement. The app knows what the coffee cost — down to the gram, from
/// her own recipes — and it knows what she took. It does not know her rent,
/// her wifi, or what she pays herself, because nobody has ever typed those
/// in. So the bottom line here is **trading profit**: what the shop made
/// before the costs of being a shop. Calling it net profit would overstate
/// what she earned, and that is exactly the lie a small business least
/// needs to be told.
class BusinessReportService {
  const BusinessReportService(this._db);

  final AppDatabase _db;

  /// `2026-11` for November.
  Future<BusinessReport> forMonth(String month) async {
    final String like = '$month-%';

    final List<Map<String, Object?>> sales = await _db.db.rawQuery(
      '''
      SELECT COUNT(*)                                  AS orders,
             IFNULL(SUM(o.subtotal_centavos), 0)       AS gross,
             IFNULL(SUM(o.discount_centavos), 0)       AS discounts,
             IFNULL(SUM(o.delivery_fee_centavos), 0)   AS delivery,
             IFNULL(SUM(o.total_centavos), 0)          AS revenue,
             IFNULL(SUM(o.cogs_centavos), 0)           AS cogs,
             IFNULL(SUM(o.refunded_centavos), 0)       AS refunded,
             IFNULL(SUM(o.item_count), 0)              AS drinks
      FROM orders o
      WHERE o.status = 'completed' AND o.business_date LIKE ?
      ''',
      <Object?>[like],
    );
    final Map<String, Object?> s = sales.first;

    final Map<String, Money> received = <String, Money>{};
    for (final Map<String, Object?> row in await _db.db.rawQuery(
      '''
      SELECT p.method AS method, IFNULL(SUM(p.amount_centavos), 0) AS total
      FROM payments p
      JOIN orders o ON o.id = p.order_id
      WHERE o.status = 'completed' AND o.business_date LIKE ?
      GROUP BY p.method
      ''',
      <Object?>[like],
    )) {
      received[row['method']! as String] = Money(row['total']! as int);
    }

    final int owed = _one(
      await _db.db.rawQuery(
        '''
      SELECT IFNULL(SUM(total_centavos), 0) AS v FROM orders
      WHERE status = 'completed' AND payment_state = 'unpaid'
        AND business_date LIKE ?
      ''',
        <Object?>[like],
      ),
    );

    final int bought = _one(
      await _db.db.rawQuery(
        'SELECT IFNULL(SUM(total_centavos), 0) AS v FROM purchases '
        'WHERE business_date LIKE ?',
        <Object?>[like],
      ),
    );

    final int wasted = _one(
      await _db.db.rawQuery(
        'SELECT IFNULL(SUM(value_centavos), 0) AS v FROM waste '
        'WHERE business_date LIKE ?',
        <Object?>[like],
      ),
    );

    final int voided = _one(
      await _db.db.rawQuery(
        'SELECT IFNULL(SUM(amount_centavos), 0) AS v FROM order_voids '
        'WHERE business_date LIKE ?',
        <Object?>[like],
      ),
    );

    // What is on the shelf right now, at what it cost. Not a month figure —
    // a photograph of today — and labelled as such wherever it is shown.
    final int shelf = _one(
      await _db.db.rawQuery('''
      SELECT IFNULL(SUM(
               i.qty_milli * IFNULL((
                 SELECT h.unit_cost_centavos_per_1000_base
                 FROM ingredient_cost_history h
                 WHERE h.ingredient_id = i.ingredient_id
                 ORDER BY h.effective_from DESC, h.id DESC LIMIT 1
               ), 0) / 1000000
             ), 0) AS v
      FROM inventory i
      WHERE i.qty_milli > 0
      '''),
    );

    final int tradingDays = _one(
      await _db.db.rawQuery(
        '''
      SELECT COUNT(DISTINCT business_date) AS v FROM orders
      WHERE status = 'completed' AND business_date LIKE ?
      ''',
        <Object?>[like],
      ),
    );

    return BusinessReport(
      month: month,
      orderCount: s['orders']! as int,
      drinkCount: s['drinks']! as int,
      tradingDays: tradingDays,
      grossSales: Money(s['gross']! as int),
      discounts: Money(s['discounts']! as int),
      deliveryFees: Money(s['delivery']! as int),
      revenue: Money(s['revenue']! as int),
      cogs: Money(s['cogs']! as int),
      refunds: Money(s['refunded']! as int),
      waste: Money(wasted),
      voids: Money(voided),
      receivedByMethod: received,
      stillOwed: Money(owed),
      spentOnStock: Money(bought),
      stockOnHand: Money(shelf),
    );
  }

  /// When the shop is busy, by hour of the day.
  ///
  /// For a one-person shop this is the report that changes behaviour: it
  /// says which hours are worth being open for, and which are worth
  /// prepping in.
  Future<List<BusyPeriod>> byHour(String month) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT strftime('%H', o.created_at, 'localtime') AS bucket,
             COUNT(*) AS orders,
             IFNULL(SUM(o.total_centavos), 0) AS revenue
      FROM orders o
      WHERE o.status = 'completed' AND o.business_date LIKE ?
      GROUP BY bucket ORDER BY bucket
      ''',
      <Object?>['$month-%'],
    );
    return <BusyPeriod>[
      for (final Map<String, Object?> r in rows)
        BusyPeriod(
          label: '${r['bucket']}:00',
          orderCount: r['orders']! as int,
          revenue: Money(r['revenue']! as int),
        ),
    ];
  }

  /// Which days of the week earn their keep.
  Future<List<BusyPeriod>> byWeekday(String month) async {
    const List<String> names = <String>[
      'Sunday',
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ];
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT strftime('%w', o.business_date) AS bucket,
             COUNT(*) AS orders,
             IFNULL(SUM(o.total_centavos), 0) AS revenue
      FROM orders o
      WHERE o.status = 'completed' AND o.business_date LIKE ?
      GROUP BY bucket ORDER BY bucket
      ''',
      <Object?>['$month-%'],
    );
    return <BusyPeriod>[
      for (final Map<String, Object?> r in rows)
        BusyPeriod(
          label: names[int.parse(r['bucket']! as String)],
          orderCount: r['orders']! as int,
          revenue: Money(r['revenue']! as int),
        ),
    ];
  }

  /// Every discount she gave, grouped by what she called it.
  Future<List<DiscountGiven>> discountsGiven(String month) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT d.name AS name, COUNT(*) AS times,
             IFNULL(SUM(d.amount_centavos), 0) AS total
      FROM order_discounts d
      JOIN orders o ON o.id = d.order_id
      WHERE o.status = 'completed' AND o.business_date LIKE ?
      GROUP BY d.name ORDER BY total DESC
      ''',
      <Object?>['$month-%'],
    );
    return <DiscountGiven>[
      for (final Map<String, Object?> r in rows)
        DiscountGiven(
          label: r['name']! as String,
          times: r['times']! as int,
          total: Money(r['total']! as int),
        ),
    ];
  }

  /// What was spilled or thrown, and why.
  Future<List<WasteByReason>> wasteByReason(String month) async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      '''
      SELECT reason, COUNT(*) AS times,
             IFNULL(SUM(value_centavos), 0) AS total
      FROM waste WHERE business_date LIKE ?
      GROUP BY reason ORDER BY total DESC
      ''',
      <Object?>['$month-%'],
    );
    return <WasteByReason>[
      for (final Map<String, Object?> r in rows)
        WasteByReason(
          reason: r['reason']! as String,
          times: r['times']! as int,
          total: Money(r['total']! as int),
        ),
    ];
  }

  static int _one(List<Map<String, Object?>> rows) =>
      ((rows.first['v'] as num?) ?? 0).toInt();
}

/// A month, as a shop owner would want it set out.
class BusinessReport {
  const BusinessReport({
    required this.month,
    required this.orderCount,
    required this.drinkCount,
    required this.tradingDays,
    required this.grossSales,
    required this.discounts,
    required this.deliveryFees,
    required this.revenue,
    required this.cogs,
    required this.refunds,
    required this.waste,
    required this.voids,
    required this.receivedByMethod,
    required this.stillOwed,
    required this.spentOnStock,
    required this.stockOnHand,
  });

  final String month;
  final int orderCount;
  final int drinkCount;

  /// Days she actually sold something. The divisor that makes "per day"
  /// mean anything in a shop that does not open every day.
  final int tradingDays;

  /// What the drinks came to at menu price, before anything came off.
  final Money grossSales;
  final Money discounts;

  /// Collected from the customer for the rider and handed straight over.
  /// Hers to carry, never hers to keep.
  final Money deliveryFees;

  /// Everything that went through the till, delivery money included.
  /// Use [salesRevenue] for anything about the shop's earnings.
  final Money revenue;

  /// What the drinks cost to make, from her own recipes.
  final Money cogs;
  final Money refunds;
  final Money waste;
  final Money voids;

  final Map<String, Money> receivedByMethod;

  /// Sold but not yet paid for. A sale, and not yet money.
  final Money stillOwed;

  /// What she paid suppliers this month. Not a cost of this month's
  /// coffee — most of it is still on the shelf — which is why it belongs
  /// in the cash flow and not in the profit.
  final Money spentOnStock;

  /// What is on the shelf today, at what it cost.
  final Money stockOnHand;

  // ───────────────────────── profit and loss ─────────────────────────

  /// What the coffee earned: everything that went through the till, less
  /// the delivery money that was only passing through, less refunds.
  ///
  /// She pays the rider herself, out of what the customer handed her, so
  /// not a centavo of it stays. Counting it as revenue would flatter every
  /// margin in the app by whatever the rider charged that day.
  Money get netSales => revenue - deliveryFees - refunds;

  Money get grossProfit => netSales - cogs;

  /// After the coffee that was made and not sold.
  Money get tradingProfit => grossProfit - waste;

  /// Basis points, so it stays exact: 4512 is 45.12%.
  int? get grossMarginBp => netSales.isZero
      ? null
      : (grossProfit.centavos * 10000) ~/ netSales.centavos;

  Money? get perDay =>
      tradingDays == 0 ? null : Money(netSales.centavos ~/ tradingDays);

  Money? get perOrder =>
      orderCount == 0 ? null : Money(netSales.centavos ~/ orderCount);

  // ─────────────────────────── cash flow ───────────────────────────

  Money get received =>
      receivedByMethod.values.fold(Money.zero, (Money a, Money b) => a + b);

  /// Money in less money out. Not profit — it includes stock she has bought
  /// and not yet sold, and excludes sales she has not yet been paid for.
  /// Money in, less stock bought, less what was handed to riders.
  Money get netCashMovement => received - spentOnStock - deliveryFees;
}

/// A slice of the week or the day.
class BusyPeriod {
  const BusyPeriod({
    required this.label,
    required this.orderCount,
    required this.revenue,
  });

  final String label;
  final int orderCount;
  final Money revenue;
}

class DiscountGiven {
  const DiscountGiven({
    required this.label,
    required this.times,
    required this.total,
  });

  final String label;
  final int times;
  final Money total;
}

class WasteByReason {
  const WasteByReason({
    required this.reason,
    required this.times,
    required this.total,
  });

  final String reason;
  final int times;
  final Money total;
}
