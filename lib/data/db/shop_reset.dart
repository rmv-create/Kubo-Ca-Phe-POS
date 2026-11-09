import 'package:sqflite_common/sqlite_api.dart';

import '../../core/time/clock.dart';
import '../../domain/entities/business_settings.dart';
import 'app_database.dart';
import 'seed/menu_seeder.dart';
import 'seed/pantry_seeder.dart';

/// Empties the shop and sets it up again from scratch.
///
/// For the one window where this is a reasonable thing to want: she has
/// been poking at the app to see what it does, there are no real sales in
/// it yet, and she would rather begin properly than unpick her own
/// experiments one at a time.
///
/// It is not an undo. Everything goes: orders, customers, stock, waste,
/// deliveries, the PINs, the settings she changed. What comes back is the
/// menu and the pantry from her setup worksheet, exactly as a new install
/// would have them, and then the app asks for her PINs again.
///
/// Two things are deliberately kept.
///
/// The **migration ledger**, because the schema is not being rebuilt and
/// pretending otherwise would run every migration again over tables that
/// already exist.
///
/// The **shop's identity in the cloud** — which shop this phone belongs to
/// and as what — when there is one. Without that she would be starting
/// over as a stranger: a second shop in her Firebase beside the first, and
/// no way to point her account at it, because the record of which shop an
/// account owns is written once and never changed. Keeping it means she
/// comes back as herself, to the same shop, with the same backups behind
/// her.
class ShopReset {
  const ShopReset(this._db, this._clock);

  final AppDatabase _db;
  final Clock _clock;

  /// Tables that are the app's own bookkeeping rather than the shop's.
  static const Set<String> _notTheShops = <String>{
    'android_metadata',
    'sqlite_sequence',
    'schema_migrations',
  };

  /// Settings that say which shop this phone is and how it talks to the
  /// others. Everything else she can set again in a minute; these she
  /// cannot.
  static const List<String> _keepSettings = <String>[
    SettingKeys.syncShopId,
    SettingKeys.syncRole,
    SettingKeys.syncDeviceLabel,
    SettingKeys.syncAdmittedAt,
  ];

  Future<void> run() async {
    // Read before the transaction opens: a query against the database while
    // one of its own transactions is in flight waits for a lock that will
    // never be given up.
    final List<String> tables = await _tables();
    final Map<String, String> kept = await _keep();

    final Database db = _db.db;
    await db.execute('PRAGMA foreign_keys = OFF');
    try {
      await db.transaction((Transaction txn) async {
        // Reverse order: children before the rows they point at, so that
        // nothing is orphaned even with the checks switched off.
        for (final String table in tables.reversed) {
          await txn.delete(table);
        }
        final String now = _clock.nowIso();
        for (final MapEntry<String, String> entry in kept.entries) {
          await txn.insert('app_settings', <String, Object?>{
            'key': entry.key,
            'value': entry.value,
            'updated_at': now,
          });
        }
      });
    } finally {
      await db.execute('PRAGMA foreign_keys = ON');
    }

    // And then the shop as a new install would have it: her menu, her
    // prices, her recipes, what was on the shelf the day she wrote it down.
    await MenuSeeder(_db, _clock).seedIfEmpty();
    await PantrySeeder(_db, _clock).seedIfEmpty();
  }

  Future<Map<String, String>> _keep() async {
    final Map<String, String> kept = <String, String>{};
    for (final String key in _keepSettings) {
      final List<Map<String, Object?>> rows = await _db.db.query(
        'app_settings',
        columns: <String>['value'],
        where: 'key = ?',
        whereArgs: <Object?>[key],
        limit: 1,
      );
      final String? value = rows.isEmpty
          ? null
          : rows.first['value'] as String?;
      if (value != null && value.isNotEmpty) kept[key] = value;
    }
    return kept;
  }

  Future<List<String>> _tables() async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY rootpage",
    );
    return <String>[
      for (final Map<String, Object?> row in rows)
        if (!_notTheShops.contains(row['name'])) row['name']! as String,
    ];
  }
}
