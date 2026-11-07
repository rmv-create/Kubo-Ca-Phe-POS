import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// An order can now be finished **before** the money arrives.
///
/// Online orders are taken the other way round from the counter: the drinks
/// are rung up, the receipt is sent over Messenger, and the customer pays
/// against it. Until now the POS refused to complete an order without a
/// payment, which forced the owner either to lie about how it was paid or to
/// keep the order open in her head.
///
/// `payment_state` records which of the two an order is. Every order that
/// already exists was completed under the old rule, which required a
/// confirmed payment, so they are all `paid` — the column default says so and
/// backfills them correctly without a second statement.
///
/// Nothing about money moves here. An unpaid order writes no `payments` row
/// at all, so the cash and GCash totals in every report stay exactly as true
/// as they were: they count money that arrived, not money that was promised.
/// The sale itself still counts as a sale from the moment the drinks were
/// made, which is what it is.
class M005UnpaidOrders extends Migration {
  const M005UnpaidOrders();

  @override
  int get version => 5;

  @override
  String get name => 'unpaid_orders';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await db.execute(
      'ALTER TABLE orders ADD COLUMN payment_state TEXT NOT NULL '
      "DEFAULT 'paid'",
    );
    // The screen that chases unpaid orders asks for exactly this.
    await db.execute(
      'CREATE INDEX idx_orders_payment_state '
      'ON orders(payment_state, business_date)',
    );

    // She delivers, so the POS should offer the fee without her having to go
    // looking for the switch. Only the stored "off" is flipped; the switch is
    // still hers to turn back off afterwards.
    await db.update(
      'app_settings',
      <String, Object?>{'value': '1'},
      where: 'key = ? AND value = ?',
      whereArgs: <Object?>['pos.delivery_fee_enabled', '0'],
    );
  }
}
