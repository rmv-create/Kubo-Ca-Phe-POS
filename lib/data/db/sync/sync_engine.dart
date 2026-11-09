import 'package:sqflite_common/sqlite_api.dart';

import '../../../core/time/clock.dart';
import '../../../domain/services/moving_average_cost.dart';
import '../app_database.dart';
import 'sync_change.dart';
import 'sync_codec.dart';
import 'synced_tables.dart';

/// Collects what this till has done, and takes in what the others have.
///
/// Three rules decide every merge, and they come from the data rather than
/// from a preference:
///
/// * **An event is a fact.** An order was rung up; stock came out. Facts
///   are written once and never edited, so the first version of one wins
///   and later copies of it are ignored. Nothing is ever overwritten and
///   nothing is lost.
/// * **Reference data is an opinion.** The price of a latte, a recipe, a
///   staff PIN. The most recent edit wins, row by row, by `updated_at`.
/// * **A total is neither.** Stock on hand is recomputed from the merged
///   movements rather than carried across, so two tills that both sold the
///   last cup end up agreeing on what really happened — including that the
///   shelf is now short.
class SyncEngine {
  SyncEngine({required AppDatabase database, required Clock clock})
    : _db = database,
      _clock = clock,
      _codec = SyncCodec(database.db);

  final AppDatabase _db;
  final Clock _clock;
  final SyncCodec _codec;

  static final Map<String, SyncedTable> _byName = <String, SyncedTable>{
    for (final SyncedTable t in syncedTables) t.name: t,
  };

  /// This till's own name, made once and kept.
  Future<String> deviceId() async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'sync_devices',
      columns: <String>['device_id'],
      where: 'is_this_one = 1',
      limit: 1,
    );
    return rows.first['device_id']! as String;
  }

  /// How many changes are waiting to go up.
  Future<int> pendingCount() async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      'SELECT COUNT(*) AS n FROM sync_outbox WHERE sent_at IS NULL',
    );
    return rows.first['n']! as int;
  }

  /// Queues every row of every synced table, as if the shop had just been
  /// written from scratch.
  ///
  /// A till that joins later is given the shop through the log, so the log
  /// has to contain the whole shop. Rows written before this device started
  /// syncing — the seeded menu on an install that predates it, anything the
  /// owner set up before she had an account — were never queued, because
  /// the triggers only hear about changes made while they exist.
  ///
  /// Rows already waiting are left alone rather than queued twice. Sending
  /// one twice would be harmless, since the far end recognises a change it
  /// has already taken, but it is a day's worth of someone's data.
  Future<int> enqueueEverything() async {
    int queued = 0;
    await _db.db.transaction((Transaction txn) async {
      for (final SyncedTable table in syncedTables) {
        // Derived rows are recomputed at the far end, never carried.
        if (table.kind == SyncKind.derived) continue;
        final List<Map<String, Object?>> rows = await txn.rawQuery(
          '''
          SELECT t.rowid AS rid, t.uid AS uid FROM ${table.name} t
          WHERE t.uid IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM sync_outbox o
              WHERE o.table_name = ? AND o.sent_at IS NULL
                AND (o.row_id = t.rowid OR o.row_uid = t.uid)
            )
        ''',
          <Object?>[table.name],
        );
        for (final Map<String, Object?> row in rows) {
          await txn.insert('sync_outbox', <String, Object?>{
            'table_name': table.name,
            'row_id': row['rid'],
            'row_uid': row['uid'],
            'op': 'upsert',
            'at': _clock.nowIso(),
          });
          queued++;
        }
      }
    });
    return queued;
  }

  // ─────────────────────────── going out ───────────────────────────

  /// What this till has done and not yet told anyone about.
  ///
  /// Several edits to one row collapse into one change carrying the row as
  /// it stands: the others need the answer, not the working.
  Future<List<SyncChange>> collect({int limit = 500}) async {
    final String device = await deviceId();
    final List<Map<String, Object?>> queued = await _db.db.query(
      'sync_outbox',
      where: 'sent_at IS NULL',
      orderBy: 'id',
      limit: limit,
    );

    final List<SyncChange> changes = <SyncChange>[];
    final Set<String> seen = <String>{};

    for (final Map<String, Object?> entry in queued.reversed) {
      final String table = entry['table_name']! as String;
      final String op = entry['op']! as String;
      final int? rowId = entry['row_id'] as int?;

      final String? uid = op == 'delete'
          ? entry['row_uid'] as String?
          : await _uidOfRow(table, rowId);
      // A row inserted and then deleted before any of this went out has
      // nothing left to send, and nothing anywhere else to delete.
      if (uid == null) continue;

      // Newest first, so the last word on a row is the one that travels.
      if (!seen.add('$table/$uid')) continue;

      if (op == 'delete') {
        changes.add(
          SyncChange(
            changeId: '$device:${entry['id']}',
            deviceId: device,
            table: table,
            rowUid: uid,
            op: SyncOp.delete,
            at: entry['at']! as String,
          ),
        );
        continue;
      }

      final List<Map<String, Object?>> rows = await _db.db.query(
        table,
        where: 'uid = ?',
        whereArgs: <Object?>[uid],
        limit: 1,
      );
      if (rows.isEmpty) continue;

      changes.add(
        SyncChange(
          changeId: '$device:${entry['id']}',
          deviceId: device,
          table: table,
          rowUid: uid,
          op: SyncOp.upsert,
          at: entry['at']! as String,
          data: await _codec.encode(table, rows.first),
        ),
      );
    }
    return changes.reversed.toList();
  }

  /// Marks everything up to and including [throughId] as told.
  Future<void> markSent(List<SyncChange> sent) async {
    if (sent.isEmpty) return;
    final String at = _clock.now().toUtc().toIso8601String();
    final List<int> ids = <int>[
      for (final SyncChange change in sent)
        int.parse(change.changeId.split(':').last),
    ];
    await _db.db.rawUpdate(
      'UPDATE sync_outbox SET sent_at = ? WHERE id <= ? AND sent_at IS NULL',
      <Object?>[at, ids.reduce((int a, int b) => a > b ? a : b)],
    );
  }

  // ─────────────────────────── coming in ───────────────────────────

  /// Takes in what the other tills have done.
  ///
  /// A change whose row points at something that has not arrived yet is
  /// held rather than dropped: batches do not promise to arrive in order,
  /// and an order line can easily overtake its order. Each pass applies
  /// what it can and tries the rest again, until a pass changes nothing.
  Future<SyncApplied> apply(List<SyncChange> incoming) async {
    if (incoming.isEmpty) {
      return const SyncApplied(
        applied: 0,
        alreadyKnown: 0,
        waitingForParent: 0,
        ignoredAsOlder: 0,
      );
    }

    final String me = await deviceId();
    int applied = 0;
    int known = 0;
    int older = 0;

    // Nothing that arrives from elsewhere is told back to the others: they
    // each hear it from the till it happened on.
    final int echoFrom = await _highestOutboxId();

    List<SyncChange> pending = <SyncChange>[
      for (final SyncChange change in incoming)
        if (change.deviceId != me) change,
    ];

    while (pending.isNotEmpty) {
      final List<SyncChange> deferred = <SyncChange>[];
      bool progress = false;

      for (final SyncChange change in pending) {
        final _Outcome outcome = await _applyOne(change);
        switch (outcome) {
          case _Outcome.applied:
            applied++;
            progress = true;
          case _Outcome.alreadyKnown:
            known++;
            progress = true;
          case _Outcome.older:
            older++;
            progress = true;
          case _Outcome.waiting:
            deferred.add(change);
        }
      }

      if (!progress || deferred.length == pending.length) {
        pending = deferred;
        break;
      }
      pending = deferred;
    }

    await _suppressEcho(echoFrom);
    if (applied > 0) await rebuildStock();

    return SyncApplied(
      applied: applied,
      alreadyKnown: known,
      waitingForParent: pending.length,
      ignoredAsOlder: older,
    );
  }

  Future<_Outcome> _applyOne(SyncChange change) async {
    final SyncedTable? table = _byName[change.table];
    // A table this version does not know about. Older app, newer till:
    // better to skip it than to guess.
    if (table == null) return _Outcome.alreadyKnown;

    if (await _alreadyTaken(change.changeId)) return _Outcome.alreadyKnown;

    final List<Map<String, Object?>> existing = await _db.db.query(
      change.table,
      where: 'uid = ?',
      whereArgs: <Object?>[change.rowUid],
      limit: 1,
    );

    if (change.op == SyncOp.delete) {
      if (existing.isNotEmpty) {
        await _db.db.delete(
          change.table,
          where: 'uid = ?',
          whereArgs: <Object?>[change.rowUid],
        );
      }
      await _remember(change);
      return _Outcome.applied;
    }

    if (existing.isNotEmpty) {
      switch (table.kind) {
        // It happened once. The first telling stands.
        case SyncKind.event:
          await _remember(change);
          return _Outcome.alreadyKnown;
        // Rebuilt from the events, never taken from the wire.
        case SyncKind.derived:
          await _remember(change);
          return _Outcome.alreadyKnown;
        case SyncKind.reference:
          final String mine = existing.first['updated_at'] as String? ?? '';
          final String theirs = change.data['updated_at'] as String? ?? '';
          if (theirs.compareTo(mine) <= 0) {
            await _remember(change);
            return _Outcome.older;
          }
      }
    }

    final Map<String, Object?>? row = await _codec.decode(
      change.table,
      change.data,
    );
    if (row == null) return _Outcome.waiting;

    if (existing.isEmpty) {
      try {
        await _db.db.insert(change.table, <String, Object?>{
          ...row,
          'uid': change.rowUid,
        });
      } on DatabaseException catch (error) {
        // The same thing under a different name: two tills set up
        // separately, each having made its own "Classics" category. There
        // is nothing to merge — the row is already here — and inventing a
        // second one would be worse than leaving it.
        if (!error.isUniqueConstraintError()) rethrow;
        await _remember(change);
        return _Outcome.alreadyKnown;
      }
    } else {
      await _db.db.update(
        change.table,
        row,
        where: 'uid = ?',
        whereArgs: <Object?>[change.rowUid],
      );
    }
    await _remember(change);
    return _Outcome.applied;
  }

  /// Rebuilds stock on hand from the ledger.
  ///
  /// The only honest way to combine two tills' stock: add up what both of
  /// them actually took out. If that leaves a shelf below zero, it says so
  /// — she really did sell more than she had, and a number clamped at zero
  /// would hide the one thing she needs to know.
  Future<void> rebuildStock() async {
    await _db.db.execute('''
      INSERT INTO inventory (ingredient_id, qty_milli, updated_at)
      SELECT m.ingredient_id,
             IFNULL(SUM(m.qty_milli_delta), 0),
             strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
      FROM inventory_movements m
      GROUP BY m.ingredient_id
      ON CONFLICT(ingredient_id) DO UPDATE SET
        qty_milli = excluded.qty_milli,
        updated_at = excluded.updated_at
    ''');

    // What the shelf cost is derived the same way, and for the same reason:
    // a delivery from the other till can land before or after ours, and the
    // average has to come out the same on both phones either way.
    await const MovingAverageCost().rebuildAll(_db.db);
  }

  Future<String?> _uidOfRow(String table, int? rowId) async {
    if (rowId == null) return null;
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      'SELECT uid FROM $table WHERE rowid = ?',
      <Object?>[rowId],
    );
    return rows.isEmpty ? null : rows.first['uid'] as String?;
  }

  Future<bool> _alreadyTaken(String changeId) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'sync_inbox',
      columns: <String>['id'],
      where: 'change_id = ?',
      whereArgs: <Object?>[changeId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> _remember(SyncChange change) async {
    await _db.db.insert('sync_inbox', <String, Object?>{
      'change_id': change.changeId,
      'device_id': change.deviceId,
      'table_name': change.table,
      'row_uid': change.rowUid,
      'op': change.op == SyncOp.delete ? 'delete' : 'upsert',
      'at': change.at,
      'applied_at': _clock.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<int> _highestOutboxId() async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      'SELECT IFNULL(MAX(id), 0) AS m FROM sync_outbox',
    );
    return rows.first['m']! as int;
  }

  /// Everything the triggers queued while another till's changes were being
  /// written is marked as already told: it was not this till's news.
  Future<void> _suppressEcho(int from) async {
    await _db.db.rawUpdate(
      'UPDATE sync_outbox SET sent_at = ? WHERE id > ? AND sent_at IS NULL',
      <Object?>[_clock.now().toUtc().toIso8601String(), from],
    );
  }
}

enum _Outcome { applied, alreadyKnown, older, waiting }
