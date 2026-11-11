import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Lets a waste entry be taken back.
///
/// Waste was write-only: a slip of the finger that said 500 g instead of
/// 50 g took 450 g of coffee off the shelf and out of the month's profit,
/// and there was nothing she could do about it afterwards. The number she
/// actually has on the shelf is the one thing the app must not be wrong
/// about, so it has to be correctable.
///
/// A void is kept rather than deleted, for the same reason an order's is.
/// Something did happen — she wrote it down — and the honest record is that
/// it was written down and then undone, not that it never was. The entry
/// stays in the list, struck through, with the reason beside it.
class M017WasteCanBeUndone extends Migration {
  const M017WasteCanBeUndone();

  @override
  int get version => 17;

  @override
  String get name => 'waste_can_be_undone';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await db.execute('ALTER TABLE waste ADD COLUMN voided_at TEXT');
    await db.execute('ALTER TABLE waste ADD COLUMN void_reason TEXT');
    await db.execute(
      'CREATE INDEX idx_waste_voided ON waste(voided_at, business_date)',
    );
  }
}
