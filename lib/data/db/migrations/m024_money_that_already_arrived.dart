import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Puts back the orders that were paid for on one phone and still stand as
/// owed on the other.
///
/// A sale is written once, so the sync engine took every later telling of
/// an order to be a repeat and dropped it. But some things about a sale
/// genuinely happen afterwards — the money arrives on an order that went
/// out on credit, the order is voided — and those were being dropped with
/// the repeats. The payment itself crossed, because a payment is its own
/// record; the word 'paid' on the order did not.
///
/// So her phone showed a hundred and twelve orders as still owed while
/// holding, in its own books, the confirmed payments for them. The engine
/// no longer loses that. This is for the orders it already lost it on.
///
/// Both halves read only what is already on this phone, and neither
/// invents anything: an order is marked paid only where a confirmed
/// payment for it is sitting right here, and voided only where this phone
/// holds the void. Nothing is moved the other way — an order this phone
/// knows to be paid is never talked back into being owed.
class M024MoneyThatAlreadyArrived extends Migration {
  const M024MoneyThatAlreadyArrived();

  @override
  int get version => 24;

  @override
  String get name => 'money_that_already_arrived';

  @override
  Future<void> up(DatabaseExecutor db) async {
    // Paid for, and still being asked for.
    await db.execute('''
      UPDATE orders SET payment_state = 'paid'
      WHERE payment_state = 'unpaid'
        AND EXISTS (
          SELECT 1 FROM payments p
          WHERE p.order_id = orders.id AND p.status = 'confirmed'
        )
    ''');

    // Taken back on one phone, still standing on this one — and still
    // counted in the day's takings until it is put right.
    await db.execute('''
      UPDATE orders SET status = 'voided'
      WHERE status = 'completed'
        AND EXISTS (
          SELECT 1 FROM order_voids v WHERE v.order_id = orders.id
        )
    ''');

    // The same money, written down twice.
    //
    // While her phone was showing a paid order as still owed, the way to
    // make it stop asking was to receive the payment again — so she did,
    // on orders the barista had already been paid for. An order is only
    // ever paid in full and in one go, so a second confirmed payment on
    // one order is the same money counted twice, and it was being added
    // to the cash and GCash totals she reconciles against the tin.
    //
    // The duplicate is not deleted. Her books should not lose a line
    // because of a fault in mine, and the record of what she did that day
    // is worth keeping. It is stood down to 'pending' instead, which the
    // takings no longer count, and which can be read back if she ever
    // wants to know what happened here. The first recording of the money
    // — the one the customer actually handed over against — stands.
    await db.execute('''
      UPDATE payments SET status = 'pending'
      WHERE status = 'confirmed'
        AND id NOT IN (
          SELECT MIN(id) FROM payments
          WHERE status = 'confirmed'
          GROUP BY order_id
        )
    ''');
  }
}
