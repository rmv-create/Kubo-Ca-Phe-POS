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
  }
}
