import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Adds the distinction between a choice the operator is *asked* for and one
/// she only opens *if the customer brings it up*.
///
/// The owner's setup answers repeatedly said "not proactively asking" for ice,
/// sweetness, syrup, sauce and extras: those are offered, but she does not want
/// to be walked through them on every drink. Modelling that as data rather than
/// as a hard-coded screen rule keeps the fast path fast — the drink adds on its
/// defaults, and the quiet groups sit behind one "More options" tap.
///
/// Also adds a continuous order sequence, because order numbers are to run
/// `K-0001` onwards and must **not** restart each day.
class M002CustomisationPrompting extends Migration {
  const M002CustomisationPrompting();

  @override
  int get version => 2;

  @override
  String get name => 'customisation_prompting';

  @override
  Future<void> up(DatabaseExecutor db) async {
    // 1 = shown as soon as the drink is opened.
    // 0 = offered, but folded away until the operator asks for it.
    await db.execute(
      'ALTER TABLE customization_groups '
      'ADD COLUMN is_proactive INTEGER NOT NULL DEFAULT 1 '
      'CHECK (is_proactive IN (0, 1))',
    );

    // Per product (and optionally per size) override of the above. NULL means
    // "use whatever the group says".
    await db.execute(
      'ALTER TABLE product_customization_groups '
      'ADD COLUMN is_proactive_override INTEGER '
      'CHECK (is_proactive_override IS NULL OR is_proactive_override IN (0, 1))',
    );

    // Monotonic across the life of the business, independent of trading day.
    await db.execute('ALTER TABLE orders ADD COLUMN sequence_no INTEGER');
    await db.execute(
      'CREATE INDEX idx_orders_sequence ON orders(sequence_no DESC)',
    );
  }
}
