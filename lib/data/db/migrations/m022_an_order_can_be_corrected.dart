import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Lets a finished order be put right without being cancelled.
///
/// The customer changes their mind after the order is marked complete — one
/// more drink, a larger size — and the owner should be able to correct the
/// order she already has rather than void it and ring up a second one with
/// a second number.
///
/// An order is otherwise written once and never altered, and that is
/// exactly why two phones can agree about the day's takings: neither of
/// them has to decide whose version of a sale is the real one. A correction
/// needs an answer to that question, so it is given one — the moment the
/// correction was made. The latest correction is the one both phones keep,
/// which is the same rule the menu and the customer list already use, and
/// an order nobody has corrected has no `edited_at` at all and goes on
/// being written once.
class M022AnOrderCanBeCorrected extends Migration {
  const M022AnOrderCanBeCorrected();

  @override
  int get version => 22;

  @override
  String get name => 'an_order_can_be_corrected';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await db.execute('ALTER TABLE orders ADD COLUMN edited_at TEXT');
  }
}
