import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Remembers whether a choice on a drink was the one it comes with anyway.
///
/// A receipt that lists "Regular sweetness · Regular strength · Regular ice ·
/// Full Cream milk" under every drink is four lines telling the customer
/// nothing: that is simply what the drink is. What they want to see is what
/// was *different* about theirs — less sweet, no ice, oat.
///
/// The POS already knew which choices were defaults while the order was
/// being taken; it was the one thing about an option it did not write down.
/// So it is written down now, beside the names and the price, as a snapshot
/// of how things stood when the drink was sold. A default she changes next
/// month does not rewrite what an old receipt says about an old drink.
///
/// Null means an order sold before this existed, where nobody recorded it.
/// Those receipts keep printing every choice, which is what they did when
/// they were issued.
class M018ReceiptShowsChanges extends Migration {
  const M018ReceiptShowsChanges();

  @override
  int get version => 18;

  @override
  String get name => 'receipt_shows_changes';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await db.execute(
      'ALTER TABLE order_item_customizations '
      'ADD COLUMN was_default_snapshot INTEGER',
    );
  }
}
