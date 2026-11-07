import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Two corrections from the owner, both about words on a screen.
///
/// **"Sizes of drinks are Small and Large."** The app shipped with Small and
/// Grande. Her menu card says `S 12oz` and `L 16oz`, so Grande becomes Large.
/// The size keeps its row, so every recipe, price and past order still points
/// at the same size; only what it is called changes. An order already sold
/// keeps the name it was sold under — `size_name_snapshot` on the line — so
/// an old receipt still reads "Grande" if that is what it said on the day.
///
/// **The ways she takes money.** Cash and GCash shipped with the app; she
/// also takes Maya, MariBank and BPI. Added switched on and in the order she
/// listed them. She can add, rename and retire any of them herself under
/// Manage → Payment methods.
class M009SizesAndPaymentMethods extends Migration {
  const M009SizesAndPaymentMethods();

  @override
  int get version => 9;

  @override
  String get name => 'sizes_and_payment_methods';

  /// code → label, in the order she wrote them.
  static const Map<String, String> _methods = <String, String>{
    'maya': 'Maya',
    'maribank': 'MariBank',
    'bpi': 'BPI',
  };

  @override
  Future<void> up(DatabaseExecutor db) async {
    final String now = DateTime.now().toUtc().toIso8601String();

    await db.update(
      'sizes',
      <String, Object?>{'code': 'large', 'name': 'Large', 'updated_at': now},
      where: 'code = ? AND name = ? COLLATE NOCASE',
      whereArgs: <Object?>['grande', 'Grande'],
    );

    // Cash and GCash were written when the table was made, so there is
    // always something here; this only skips a code she has added herself.
    final List<Map<String, Object?>> existing = await db.query(
      'payment_methods',
      columns: <String>['code'],
    );
    final Set<String> have = <String>{
      for (final Map<String, Object?> row in existing)
        (row['code']! as String).toLowerCase(),
    };

    final List<Map<String, Object?>> last = await db.rawQuery(
      'SELECT IFNULL(MAX(display_order), 0) AS m FROM payment_methods',
    );
    int order = last.first['m']! as int;

    for (final MapEntry<String, String> method in _methods.entries) {
      if (have.contains(method.key)) continue;
      await db.insert('payment_methods', <String, Object?>{
        'code': method.key,
        'name': method.value,
        // Money that lands in an app or an account the POS cannot see, so
        // she confirms it arrived before the order counts as paid — the same
        // rule GCash already follows.
        'needs_confirmation': 1,
        'takes_reference': 1,
        'takes_tendered': 0,
        'is_active': 1,
        'display_order': ++order,
        'created_at': now,
        'updated_at': now,
      });
    }
  }
}
