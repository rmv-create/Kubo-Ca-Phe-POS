import 'dart:convert';

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
    if (queued.isEmpty) return const <SyncChange>[];

    // Which uid each queued row has, one question per table rather than one
    // per row. Ten orders queue a hundred changes; asking a hundred times
    // over was most of the time a round took, and on a phone's browser every
    // question is a message to the database and back.
    final Map<String, Set<int>> rowIds = <String, Set<int>>{};
    for (final Map<String, Object?> entry in queued) {
      if (entry['op'] == 'delete') continue;
      final int? rowId = entry['row_id'] as int?;
      if (rowId == null) continue;
      (rowIds[entry['table_name']! as String] ??= <int>{}).add(rowId);
    }
    final Map<String, Map<int, String>> uids = <String, Map<int, String>>{};
    for (final MapEntry<String, Set<int>> wanted in rowIds.entries) {
      final Map<int, String> found = <int, String>{};
      for (final List<int> some in _inHandfuls(wanted.value.toList())) {
        // rowid rather than id: app_settings is keyed by its name, and has
        // no id column, but every table has a rowid.
        final List<Map<String, Object?>> rows = await _db.db.rawQuery(
          'SELECT rowid AS rid, uid FROM ${wanted.key} '
          'WHERE rowid IN (${_holes(some.length)})',
          some,
        );
        for (final Map<String, Object?> row in rows) {
          final String? uid = row['uid'] as String?;
          if (uid != null) found[row['rid']! as int] = uid;
        }
      }
      uids[wanted.key] = found;
    }

    // Newest first, so the last word on a row is the one that travels.
    final List<_Queued> travelling = <_Queued>[];
    final Set<String> seen = <String>{};
    for (final Map<String, Object?> entry in queued.reversed) {
      final String table = entry['table_name']! as String;
      final String op = entry['op']! as String;
      final int? rowId = entry['row_id'] as int?;

      final String? uid = op == 'delete'
          ? entry['row_uid'] as String?
          : (rowId == null ? null : uids[table]?[rowId]);
      // A row inserted and then deleted before any of this went out has
      // nothing left to send, and nothing anywhere else to delete.
      if (uid == null) continue;
      if (!seen.add('$table/$uid')) continue;

      travelling.add(
        _Queued(
          id: entry['id']! as int,
          table: table,
          uid: uid,
          at: entry['at']! as String,
          isDelete: op == 'delete',
        ),
      );
    }

    // And the rows themselves, again one question per table.
    final Map<String, Set<String>> needed = <String, Set<String>>{};
    for (final _Queued q in travelling) {
      if (q.isDelete) continue;
      (needed[q.table] ??= <String>{}).add(q.uid);
    }
    final Map<String, Map<String, Map<String, Object?>>> bodies =
        <String, Map<String, Map<String, Object?>>>{};
    for (final MapEntry<String, Set<String>> wanted in needed.entries) {
      final Map<String, Map<String, Object?>> found =
          <String, Map<String, Object?>>{};
      for (final List<String> some in _inHandfuls(wanted.value.toList())) {
        final List<Map<String, Object?>> rows = await _db.db.query(
          wanted.key,
          where: 'uid IN (${_holes(some.length)})',
          whereArgs: some,
        );
        for (final Map<String, Object?> row in rows) {
          found[row['uid']! as String] = row;
        }
      }
      bodies[wanted.key] = found;
    }

    final List<SyncChange> changes = <SyncChange>[];
    for (final _Queued q in travelling) {
      if (q.isDelete) {
        changes.add(
          SyncChange(
            changeId: '$device:${q.id}',
            deviceId: device,
            table: q.table,
            rowUid: q.uid,
            op: SyncOp.delete,
            at: q.at,
          ),
        );
        continue;
      }

      final Map<String, Object?>? row = bodies[q.table]?[q.uid];
      if (row == null) continue;

      changes.add(
        SyncChange(
          changeId: '$device:${q.id}',
          deviceId: device,
          table: q.table,
          rowUid: q.uid,
          op: SyncOp.upsert,
          at: q.at,
          data: await _codec.encode(q.table, row),
        ),
      );
    }
    return changes.reversed.toList();
  }

  /// Splits a list into lengths SQLite will take as query arguments.
  static Iterable<List<T>> _inHandfuls<T>(List<T> all, {int of = 200}) =>
      <List<T>>[
        for (int i = 0; i < all.length; i += of)
          all.sublist(i, i + of > all.length ? all.length : i + of),
      ];

  static String _holes(int count) => List<String>.filled(count, '?').join(',');

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

  // ────────────────────── what is still waiting ──────────────────────

  /// The changes this till is holding until the rows they point at arrive.
  Future<List<SyncChange>> waitingRoom({int limit = 2000}) async {
    final List<Map<String, Object?>> rows = await _db.db.query(
      'sync_waiting',
      columns: <String>['payload'],
      orderBy: 'first_seen, change_id',
      limit: limit,
    );
    return <SyncChange>[
      for (final Map<String, Object?> row in rows)
        SyncChange.fromJson(
          jsonDecode(row['payload']! as String) as Map<String, Object?>,
        ),
    ];
  }

  /// Writes down what is still waiting, and forgets what no longer is.
  ///
  /// The round has just tried everything it was holding along with the new
  /// page, so whatever is not in [stillWaiting] has been dealt with — it
  /// went in, or it was already known, or it was older than what is here.
  Future<void> keepWaiting(List<SyncChange> stillWaiting) async {
    final String now = _clock.now().toUtc().toIso8601String();
    await _db.db.transaction((Transaction txn) async {
      final Map<String, int> triedBefore = <String, int>{
        for (final Map<String, Object?> row in await txn.query(
          'sync_waiting',
          columns: <String>['change_id', 'tries'],
        ))
          row['change_id']! as String: row['tries']! as int,
      };
      await txn.delete('sync_waiting');
      final Batch batch = txn.batch();
      for (final SyncChange change in stillWaiting) {
        batch.insert('sync_waiting', <String, Object?>{
          'change_id': change.changeId,
          'payload': jsonEncode(change.toJson()),
          'first_seen': now,
          'tries': (triedBefore[change.changeId] ?? 0) + 1,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (stillWaiting.isNotEmpty) await batch.commit(noResult: true);
    });
  }

  /// How many changes are being held. For the sync screen.
  Future<int> waitingCount() async {
    final List<Map<String, Object?>> rows = await _db.db.rawQuery(
      'SELECT COUNT(*) AS n FROM sync_waiting',
    );
    return (rows.first['n'] as int?) ?? 0;
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

    // Which of these we have taken in before, asked once for the whole
    // batch. Asking per change — and again on every pass over what is
    // waiting for its parent — was the single biggest part of taking a
    // round in, and on a phone's browser each ask is a message to the
    // database and back.
    _taken = await _alreadyTakenAmong(<String>[
      for (final SyncChange change in incoming) change.changeId,
    ]);

    // Nothing that arrives from elsewhere is told back to the others: they
    // each hear it from the till it happened on.
    final int echoFrom = await _highestOutboxId();

    List<SyncChange> pending = _parentsFirst(<SyncChange>[
      for (final SyncChange change in incoming)
        if (change.deviceId != me) change,
    ], await _applicationOrder());

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

    _taken = null;
    await _suppressEcho(echoFrom);
    if (applied > 0) await rebuildStock();

    return SyncApplied(
      applied: applied,
      alreadyKnown: known,
      waitingForParent: pending.length,
      ignoredAsOlder: older,
      stillWaiting: pending,
    );
  }

  /// The same changes, in an order that does not make them wait on each
  /// other.
  ///
  /// An order's own row travels *after* its lines, because finishing a sale
  /// writes the order, then its lines and its stock movements, and then goes
  /// back and writes the order's cost of goods — and it is that last word
  /// that travels. Applied in the order they were written, every line and
  /// every movement arrives before the order it belongs to, is held back as
  /// an orphan, and has to be tried again on a second pass: twice the work,
  /// every round, and on a phone's browser that is felt.
  ///
  /// So they are applied in an order that respects what points at what,
  /// while leaving two changes to the same row in the order they arrived —
  /// there the later one really is the last word.
  static List<SyncChange> _parentsFirst(
    List<SyncChange> changes,
    Map<String, int> ranks,
  ) {
    final List<int> order = <int>[for (int i = 0; i < changes.length; i++) i];
    final int last = ranks.length;
    order.sort((int a, int b) {
      final int byTable =
          (ranks[changes[a].table] ?? last) - (ranks[changes[b].table] ?? last);
      return byTable != 0 ? byTable : a - b;
    });
    return <SyncChange>[for (final int i in order) changes[i]];
  }

  static Map<String, int>? _ranks;

  /// How deep each table sits in the web of pointers: nothing is applied
  /// before the rows it points at.
  ///
  /// Read from the database's own foreign keys rather than written down
  /// here, for the same reason the codec reads them — a table that gains a
  /// reference later cannot be forgotten about. Worked out once and kept,
  /// because the schema does not change while the app is running.
  Future<Map<String, int>> _applicationOrder() async {
    final Map<String, int>? known = _ranks;
    if (known != null) return known;

    final Map<String, Set<String>> pointsAt = <String, Set<String>>{};
    for (final SyncedTable table in syncedTables) {
      final Map<String, String> references = await _codec.referencesOf(
        table.name,
      );
      pointsAt[table.name] = <String>{
        for (final String target in references.values)
          if (target != table.name && _byName.containsKey(target)) target,
      };
    }

    final Map<String, int> depth = <String, int>{};
    final Set<String> working = <String>{};

    int depthOf(String table) {
      final int? settled = depth[table];
      if (settled != null) return settled;
      // A cycle cannot be ordered, so it is left where it is rather than
      // sending this looking for itself for ever.
      if (!working.add(table)) return 0;
      int deepest = 0;
      for (final String target in pointsAt[table] ?? const <String>{}) {
        final int below = depthOf(target) + 1;
        if (below > deepest) deepest = below;
      }
      working.remove(table);
      return depth[table] = deepest;
    }

    for (final SyncedTable table in syncedTables) {
      depthOf(table.name);
    }
    return _ranks = depth;
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
        try {
          await _db.db.delete(
            change.table,
            where: 'uid = ?',
            whereArgs: <Object?>[change.rowUid],
          );
        } on DatabaseException catch (error) {
          // Something here still points at it, and the row that points is
          // on its way out too — deleting an order sends the void away
          // with it, and the two can arrive in either order. The schema
          // holds the order until its void has gone, which is right; this
          // just waits for that rather than giving up.
          //
          // This is the failure she actually hit: practice orders deleted
          // on one phone stopped the other phone syncing altogether.
          if (_isMissingParent(error)) return _Outcome.waiting;
          rethrow;
        }
      }
      await _remember(change);
      return _Outcome.applied;
    }

    final bool correcting =
        existing.isNotEmpty && _isACorrection(change, existing.first);

    if (existing.isNotEmpty) {
      switch (table.kind) {
        // It happened once. The first telling stands — unless the owner has
        // since put the order right, which is the one correction a sale
        // accepts. Then the later correction stands, on both phones.
        case SyncKind.event:
          if (correcting) break;
          // A sale is written once, but a few things about it genuinely
          // happen afterwards: the money arrives on an order that went out
          // on credit, the order is voided, it is put under a customer's
          // name. Those are later facts about the same sale, not a second
          // telling of it, and dropping them was costing her real money —
          // a hundred and twelve orders she had been paid for still stood
          // as owed on the other phone, because 'paid' never crossed.
          final Map<String, Object?>? since = await _afterwards(
            change,
            existing.first,
          );
          if (since != null) {
            await _db.db.update(
              change.table,
              since,
              where: 'uid = ?',
              whereArgs: <Object?>[change.rowUid],
            );
            await _remember(change);
            return _Outcome.applied;
          }
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
        if (error.isUniqueConstraintError()) {
          return _settleClash(change, row, table);
        }
        // The row points at something that has not landed yet: an order
        // line ahead of its order, a recipe item ahead of its ingredient.
        // That is ordinary — the log is a stream of rows, not a tree — and
        // the loop above exists precisely to come back for it once the
        // parent is in. Throwing stopped the whole sync instead, so one
        // early arrival left the barista's phone showing a database error
        // and the shop not syncing at all.
        if (_isMissingParent(error)) return _Outcome.waiting;
        rethrow;
      }
    } else {
      try {
        await _db.db.update(
          change.table,
          // A corrected order keeps the number this till gave it. Two
          // tills that had to tell two orders apart by their numbers must
          // not have one of them handed back. Everything else about the
          // order — including which day it belongs to, which the owner can
          // also put right — is the correction's business.
          correcting ? _withoutIdentity(row) : row,
          where: 'uid = ?',
          whereArgs: <Object?>[change.rowUid],
        );
      } on DatabaseException catch (error) {
        // An edit can point at a new parent just as an insert can.
        if (_isMissingParent(error)) return _Outcome.waiting;
        rethrow;
      }
    }
    await _remember(change);
    return _Outcome.applied;
  }

  /// What to do when the row will not go in because something already
  /// here has the same unique key.
  ///
  /// It depends entirely on what kind of row it is, and getting that wrong
  /// is how two separate sales were merged into one.
  /// What has happened to a sale since it was rung up, and nothing else.
  ///
  /// Every rule here only ever moves one way — owed becomes paid, a sale
  /// becomes voided, a nameless order gains a customer, a refund only
  /// grows. That is what makes it safe without a clock to referee: two
  /// phones applying each other's news in whatever order they receive it
  /// come to the same answer, and neither can talk the other backwards.
  /// Nothing about what was sold, at what price, on which day, is touched.
  Future<Map<String, Object?>?> _afterwards(
    SyncChange change,
    Map<String, Object?> mine,
  ) async {
    if (change.table != 'orders') return null;

    final Map<String, Object?>? theirs = await _codec.decode(
      change.table,
      change.data,
    );
    if (theirs == null) return null;

    final Map<String, Object?> since = <String, Object?>{};

    // The money came in. It can never go back to being owed.
    if (mine['payment_state'] == 'unpaid' &&
        theirs['payment_state'] == 'paid') {
      since['payment_state'] = 'paid';
    }

    // The sale was taken back. A void is never undone; an order that is
    // put right is corrected instead, and that goes the other way above.
    if (mine['status'] == 'completed' && theirs['status'] == 'voided') {
      since['status'] = 'voided';
    }

    // Put under somebody's name afterwards — on the orders list, or when
    // the drink is handed over and she asks who it is for.
    if (mine['customer_id'] == null && theirs['customer_id'] != null) {
      since['customer_id'] = theirs['customer_id'];
      since['customer_name_snapshot'] = theirs['customer_name_snapshot'];
    }

    // Refunds accumulate, so the larger figure is the later one.
    final int refunded = (mine['refunded_centavos'] as int?) ?? 0;
    final int alsoRefunded = (theirs['refunded_centavos'] as int?) ?? 0;
    if (alsoRefunded > refunded) since['refunded_centavos'] = alsoRefunded;

    return since.isEmpty ? null : since;
  }

  /// An order's row, without the number that says which order it is.
  static Map<String, Object?> _withoutIdentity(Map<String, Object?> row) =>
      <String, Object?>{
        for (final MapEntry<String, Object?> cell in row.entries)
          if (!_identity.contains(cell.key)) cell.key: cell.value,
      };

  static const Set<String> _identity = <String>{'order_no', 'sequence_no'};

  /// Whether an order we already have has been corrected since.
  ///
  /// Only orders, and only forwards: an order with no correction on it, or
  /// with an older one than ours, is left exactly as it is.
  static bool _isACorrection(SyncChange change, Map<String, Object?> mine) {
    if (change.table != 'orders') return false;
    final String theirs = change.data['edited_at'] as String? ?? '';
    if (theirs.isEmpty) return false;
    return theirs.compareTo(mine['edited_at'] as String? ?? '') > 0;
  }

  Future<_Outcome> _settleClash(
    SyncChange change,
    Map<String, Object?> row,
    SyncedTable table,
  ) async {
    switch (table.kind) {
      // Two tills set up separately each made their own "Iced Black". They
      // are the same thing, and joining the two names is exactly right:
      // otherwise every recipe and order line pointing at hers is stranded
      // on this phone for good.
      case SyncKind.reference:
      case SyncKind.derived:
        final bool joined = await _adopt(change.table, row, change.rowUid);
        if (!joined) {
          await _remember(change);
          return _Outcome.alreadyKnown;
        }
        await _db.db.update(
          change.table,
          row,
          where: 'uid = ?',
          whereArgs: <Object?>[change.rowUid],
        );
        await _remember(change);
        return _Outcome.applied;

      // Two sales are never the same sale. Two phones serving apart both
      // reached for 1165 because each counted from what it could see, and
      // joining those two names together put one customer's drinks inside
      // another's order — three drinks on an order that said two.
      //
      // Both sales happened, so both are kept. The one rung up first keeps
      // the number it printed; the later one is marked, by a rule both
      // phones work out the same way from what they can both see, so they
      // do not end up disagreeing about which is which.
      case SyncKind.event:
        if (change.table != 'orders') {
          // Voiding the same order on both phones, or closing the same day
          // on both: there really is only one of these, and the first
          // telling stands.
          await _remember(change);
          return _Outcome.alreadyKnown;
        }
        return _keepBothOrders(change, row);
    }
  }

  /// Keeps two orders that were given the same number on two phones.
  Future<_Outcome> _keepBothOrders(
    SyncChange change,
    Map<String, Object?> row,
  ) async {
    final String number = (row['order_no'] as String?) ?? '';
    if (number.isEmpty) {
      await _remember(change);
      return _Outcome.alreadyKnown;
    }

    final List<Map<String, Object?>> mine = await _db.db.query(
      'orders',
      columns: <String>['rowid AS rid', 'uid', 'created_at'],
      where: 'order_no = ?',
      whereArgs: <Object?>[number],
      limit: 1,
    );
    if (mine.isEmpty) return _Outcome.waiting;

    final String theirsAt = (row['created_at'] as String?) ?? '';
    final String mineAt = (mine.first['created_at'] as String?) ?? '';
    final String mineUid = (mine.first['uid'] as String?) ?? '';

    // Whoever rang up first keeps the clean number. Both phones can see
    // both orders, so both reach the same answer.
    final bool theirsIsLater =
        theirsAt.compareTo(mineAt) > 0 ||
        (theirsAt == mineAt && change.rowUid.compareTo(mineUid) > 0);

    if (theirsIsLater) {
      await _db.db.insert('orders', <String, Object?>{
        ...row,
        'order_no': _marked(number, change.rowUid),
        'uid': change.rowUid,
      });
    } else {
      // The order already here is the later one, so it gives the number up.
      await _db.db.rawUpdate(
        'UPDATE orders SET order_no = ? WHERE rowid = ?',
        <Object?>[_marked(number, mineUid), mine.first['rid']],
      );
      await _db.db.insert('orders', <String, Object?>{
        ...row,
        'uid': change.rowUid,
      });
    }

    await _remember(change);
    return _Outcome.applied;
  }

  /// The same number, marked so the two can be told apart on a list.
  ///
  /// Taken from the order's own name rather than counted, so that every
  /// phone marks it identically without having to ask the others what they
  /// have already used.
  static String _marked(String number, String uid) {
    final String tail = uid.replaceAll(RegExp('[^0-9a-zA-Z]'), '');
    return '$number-${tail.substring(0, tail.length < 4 ? tail.length : 4)}';
  }

  /// Gives the row already here the incoming row's name.
  ///
  /// Two tills set up separately each made their own "Classics", their own
  /// "Iced Black", their own "Alaska Fresh Milk". They are the same things,
  /// and the database says so by refusing the second one: the names are
  /// unique. What was missing was joining the two identities, so that a
  /// recipe or an order line written against her copy finds this one.
  ///
  /// The conflicting row is found through the table's own unique indexes
  /// rather than a list kept by hand, for the same reason the codec reads
  /// the foreign keys that way: the schema already knows.
  ///
  /// Returns false when the clash cannot be pinned to one row, in which
  /// case nothing is touched.
  Future<bool> _adopt(
    String table,
    Map<String, Object?> row,
    String uid,
  ) async {
    for (final List<String> columns in await _uniqueKeysOf(table)) {
      if (columns.any((String c) => !row.containsKey(c))) continue;

      final String where = columns
          .map((String c) => row[c] == null ? '$c IS NULL' : '$c = ?')
          .join(' AND ');
      final List<Object?> args = <Object?>[
        for (final String c in columns)
          if (row[c] != null) row[c],
      ];

      // rowid rather than id: not every synced table has an `id` column —
      // app_settings is keyed by its name — but every one of them has a
      // rowid, and that is all this needs to point at the row it found.
      final List<Map<String, Object?>> found = await _db.db.rawQuery(
        'SELECT rowid AS rid, uid FROM $table WHERE $where LIMIT 2',
        args,
      );
      if (found.length != 1) continue;
      if (found.first['uid'] == uid) return true;

      await _db.db.rawUpdate(
        'UPDATE $table SET uid = ? WHERE rowid = ?',
        <Object?>[uid, found.first['rid']],
      );
      // This row answers to a different name now, so anything already
      // worked out about which uid points where is no longer safe to reuse.
      _codec.forgetPointers();
      return true;
    }
    return false;
  }

  final Map<String, List<List<String>>> _uniqueKeys =
      <String, List<List<String>>>{};

  /// The columns of each unique index on a table, except the one on `uid`
  /// itself — which is the identity being joined up, not a way to find it.
  Future<List<List<String>>> _uniqueKeysOf(String table) async {
    final List<List<String>>? known = _uniqueKeys[table];
    if (known != null) return known;

    final List<Map<String, Object?>> indexes = await _db.db.rawQuery(
      'PRAGMA index_list($table)',
    );
    final List<List<String>> keys = <List<String>>[];
    for (final Map<String, Object?> index in indexes) {
      if (index['unique'] != 1) continue;
      final List<Map<String, Object?>> columns = await _db.db.rawQuery(
        "PRAGMA index_info('${index['name']}')",
      );
      final List<String> names = <String>[
        for (final Map<String, Object?> c in columns)
          if (c['name'] != null) c['name']! as String,
      ];
      // An index over an expression gives a null column name; it cannot be
      // matched on, so it is no use here.
      if (names.length != columns.length) continue;
      if (names.isEmpty || names.contains('uid')) continue;
      keys.add(names);
    }
    return _uniqueKeys[table] = keys;
  }

  /// Whether this failure is "its parent is not here yet" rather than
  /// anything wrong with the row.
  ///
  /// sqflite has no `isForeignKeyError`, so the code and the message are
  /// read directly. 1811 is SQLITE_CONSTRAINT_FOREIGNKEY; the text is
  /// checked too because the ffi and web builds do not always carry the
  /// extended code through.
  static bool _isMissingParent(DatabaseException error) {
    final String said = error.toString().toUpperCase();
    return said.contains('FOREIGN KEY') || said.contains('1811');
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

  /// What this batch of changes has already been through, if a round is
  /// under way. Null when one change is being applied on its own.
  Set<String>? _taken;

  Future<bool> _alreadyTaken(String changeId) async {
    final Set<String>? batch = _taken;
    if (batch != null) return batch.contains(changeId);

    final List<Map<String, Object?>> rows = await _db.db.query(
      'sync_inbox',
      columns: <String>['id'],
      where: 'change_id = ?',
      whereArgs: <Object?>[changeId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Which of [ids] are in the inbox already, in as few questions as
  /// SQLite will take arguments for.
  Future<Set<String>> _alreadyTakenAmong(List<String> ids) async {
    final Set<String> found = <String>{};
    for (final List<String> some in _inHandfuls(ids)) {
      final List<Map<String, Object?>> rows = await _db.db.rawQuery(
        'SELECT change_id FROM sync_inbox '
        'WHERE change_id IN (${_holes(some.length)})',
        some,
      );
      for (final Map<String, Object?> row in rows) {
        found.add(row['change_id']! as String);
      }
    }
    return found;
  }

  Future<void> _remember(SyncChange change) async {
    _taken?.add(change.changeId);
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

/// One queued change, once it is known what it is about.
class _Queued {
  const _Queued({
    required this.id,
    required this.table,
    required this.uid,
    required this.at,
    required this.isDelete,
  });

  final int id;
  final String table;
  final String uid;
  final String at;
  final bool isDelete;
}
