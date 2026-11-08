import 'package:sqflite_common/sqlite_api.dart';

import '../sync/synced_tables.dart';
import 'migration.dart';

/// Everything two tills need before they can ever be told to agree.
///
/// No data moves anywhere yet. This lays the three things without which a
/// merge is guesswork:
///
/// **A name every device agrees on.** Row ids here count upwards from one,
/// so order 7 on her phone and order 7 on the barista's are different
/// orders with the same name. Every synced row gets a `uid` as well — a
/// random 128-bit value, made where the row is made and never reused — and
/// that, not the id, is what crosses between devices.
///
/// **A record of what changed.** Triggers on every synced table note
/// anything inserted, changed or deleted in `sync_outbox`. Doing it in the
/// database rather than in the repositories means a write cannot be missed
/// by forgetting to call something: if it changed the table, it is in the
/// queue.
///
/// **Order numbers that cannot collide.** Each till is given a block —
/// 1001 upwards on the first, 5001 upwards on the second — so two tills
/// serving at once, with no signal between them, still cannot hand two
/// customers the same number. The block is this device's alone and is
/// never handed out again.
class M012SyncFoundations extends Migration {
  const M012SyncFoundations();

  @override
  int get version => 12;

  @override
  String get name => 'sync_foundations';

  /// How many numbers a till is given at a time. At her busiest — she said
  /// 100 to 200 drinks on a very good day — a block lasts about twenty
  /// years, so in practice a till is given one and never asks again.
  static const int orderNumberBlockSize = 4000;

  @override
  Future<void> up(DatabaseExecutor db) async {
    await _identifyEveryRow(db);
    await _queueOfChanges(db);
    await _thisDevice(db);
  }

  /// A uid column on every synced table, filled in for the rows already
  /// there, and unique from here on.
  Future<void> _identifyEveryRow(DatabaseExecutor db) async {
    for (final String table in syncedTableNames) {
      await db.execute('ALTER TABLE $table ADD COLUMN uid TEXT');
      // Existing rows were made before any of this and have no name the
      // other device knows. They get one now; both devices start from the
      // same backup, so the names match.
      await db.execute(
        'UPDATE $table SET uid = lower(hex(randomblob(16))) WHERE uid IS NULL',
      );
      await db.execute('CREATE UNIQUE INDEX idx_${table}_uid ON $table(uid)');
    }
  }

  /// The queue, and the triggers that fill it.
  Future<void> _queueOfChanges(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE sync_outbox (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT NOT NULL,
        -- Which row, in the only terms a trigger can be sure of at the
        -- moment it fires. The uid is read from the row when the change is
        -- sent, and given to it then if it does not have one yet: a trigger
        -- cannot both make a value and hand it to a second statement, and
        -- guessing at the order two triggers fire in is how this sort of
        -- thing goes quietly wrong.
        row_id     INTEGER,
        -- Set for a delete, where the row is about to stop existing and
        -- there will be nothing left to read it from.
        row_uid    TEXT,
        op         TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
        at         TEXT NOT NULL,
        -- Null until it has gone up.
        sent_at    TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_sync_outbox_pending ON sync_outbox(sent_at, id)',
    );

    // What the other tills have already told us, so the same change is
    // never applied twice.
    await db.execute('''
      CREATE TABLE sync_inbox (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        change_id   TEXT NOT NULL,
        device_id   TEXT NOT NULL,
        table_name  TEXT NOT NULL,
        row_uid     TEXT NOT NULL,
        op          TEXT NOT NULL,
        at          TEXT NOT NULL,
        applied_at  TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX idx_sync_inbox_change ON sync_inbox(change_id)',
    );

    for (final String table in syncedTableNames) {
      // Every new row is named as it is written. The outbox trigger below
      // deliberately does not read the uid — two AFTER INSERT triggers
      // have no promised order between them — so this one is free to make
      // it without anything depending on when it runs.
      await db.execute('''
        CREATE TRIGGER trg_${table}_uid AFTER INSERT ON $table
        WHEN NEW.uid IS NULL
        BEGIN
          UPDATE $table SET uid = lower(hex(randomblob(16)))
          WHERE rowid = NEW.rowid;
        END
      ''');
      await db.execute('''
        CREATE TRIGGER trg_${table}_out_ins AFTER INSERT ON $table
        BEGIN
          INSERT INTO sync_outbox (table_name, row_id, op, at)
          VALUES ('$table', NEW.rowid, 'upsert',
                  strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
        END
      ''');
      // Naming a row is not a change to it: without this the trigger above
      // would put every insert in the queue twice.
      await db.execute('''
        CREATE TRIGGER trg_${table}_out_upd AFTER UPDATE ON $table
        WHEN NOT (OLD.uid IS NULL AND NEW.uid IS NOT NULL)
        BEGIN
          INSERT INTO sync_outbox (table_name, row_id, row_uid, op, at)
          VALUES ('$table', NEW.rowid, NEW.uid, 'upsert',
                  strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
        END
      ''');
      await db.execute('''
        CREATE TRIGGER trg_${table}_out_del AFTER DELETE ON $table
        BEGIN
          INSERT INTO sync_outbox (table_name, row_uid, op, at)
          VALUES ('$table', OLD.uid, 'delete',
                  strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
        END
      ''');
    }
  }

  /// This till's own name and its block of order numbers.
  Future<void> _thisDevice(DatabaseExecutor db) async {
    final String now = DateTime.now().toUtc().toIso8601String();

    await db.execute('''
      CREATE TABLE sync_devices (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id     TEXT NOT NULL,
        label         TEXT NOT NULL,
        is_this_one   INTEGER NOT NULL DEFAULT 0 CHECK (is_this_one IN (0, 1)),
        -- The first order number this till may use. Blocks never overlap.
        number_base   INTEGER NOT NULL,
        last_seen_at  TEXT,
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX idx_sync_devices_id ON sync_devices(device_id)',
    );

    // The till this database is already on keeps the numbers it has been
    // using. A second till added later is given the next block up.
    final List<Map<String, Object?>> start = await db.rawQuery(
      "SELECT value FROM app_settings WHERE key = 'orders.number_start'",
    );
    final int base = start.isEmpty
        ? 1001
        : int.tryParse(start.first['value'] as String? ?? '') ?? 1001;

    await db.rawInsert(
      '''
      INSERT INTO sync_devices
        (device_id, label, is_this_one, number_base, created_at, updated_at)
      VALUES (lower(hex(randomblob(8))), 'This device', 1, ?, ?, ?)
      ''',
      <Object?>[base, now, now],
    );
  }
}
