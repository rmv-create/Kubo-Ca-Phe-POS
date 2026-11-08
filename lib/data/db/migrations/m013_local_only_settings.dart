import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Some settings belong to the till, not to the shop.
///
/// Where this till has got to in the other's log, when it last synced, what
/// went wrong last time: those are notes to itself. Sending them to the
/// other till would at best be noise and at worst harmful — a cursor is a
/// statement about what *this* device has already seen, and handing it to
/// another device would tell it to skip changes it has never read.
///
/// Worse, writing them is itself a change, so a till that synced once would
/// have something new to say immediately afterwards, forever.
///
/// Everything else in `app_settings` — the shop's name, its prices, what the
/// receipt says — is the shop's and still travels.
class M013LocalOnlySettings extends Migration {
  const M013LocalOnlySettings();

  @override
  int get version => 13;

  @override
  String get name => 'local_only_settings';

  /// Keys that stay on the device that wrote them.
  static const String _isLocal =
      "key LIKE 'sync.%' OR key LIKE 'cloud.%' "
      "OR key = 'backup.last_auto_date'";

  @override
  Future<void> up(DatabaseExecutor db) async {
    for (final String trigger in <String>[
      'trg_app_settings_out_ins',
      'trg_app_settings_out_upd',
      'trg_app_settings_out_del',
    ]) {
      await db.execute('DROP TRIGGER IF EXISTS $trigger');
    }

    final String localNew = _isLocal.replaceAll('key', 'NEW.key');
    final String localOld = _isLocal.replaceAll('key', 'OLD.key');

    await db.execute('''
      CREATE TRIGGER trg_app_settings_out_ins AFTER INSERT ON app_settings
      WHEN NOT ($localNew)
      BEGIN
        INSERT INTO sync_outbox (table_name, row_id, op, at)
        VALUES ('app_settings', NEW.rowid, 'upsert',
                strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
      END
    ''');
    await db.execute('''
      CREATE TRIGGER trg_app_settings_out_upd AFTER UPDATE ON app_settings
      WHEN NOT ($localNew)
        AND NOT (OLD.uid IS NULL AND NEW.uid IS NOT NULL)
      BEGIN
        INSERT INTO sync_outbox (table_name, row_id, row_uid, op, at)
        VALUES ('app_settings', NEW.rowid, NEW.uid, 'upsert',
                strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
      END
    ''');
    await db.execute('''
      CREATE TRIGGER trg_app_settings_out_del AFTER DELETE ON app_settings
      WHEN NOT ($localOld)
      BEGIN
        INSERT INTO sync_outbox (table_name, row_uid, op, at)
        VALUES ('app_settings', OLD.uid, 'delete',
                strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
      END
    ''');

    // Anything of this kind already queued is this till's own business.
    await db.execute('''
      DELETE FROM sync_outbox
      WHERE table_name = 'app_settings'
        AND row_id IN (SELECT rowid FROM app_settings WHERE $_isLocal)
    ''');
  }
}
