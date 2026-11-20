import 'package:sqflite_common/sqlite_api.dart';

/// Turns a row into something another till can understand, and back.
///
/// The only hard part of this is pointers. `order_items.order_id` holds a
/// number that means one order here and a different one — or nothing at all
/// — over there. So on the way out every foreign key is swapped for the uid
/// of the row it points at, and on the way in the uid is looked up and
/// swapped back for whatever id that row has here.
///
/// Which columns are foreign keys is not written down twice: it is read
/// from the database itself, so a table that gains a reference later cannot
/// be forgotten about here.
class SyncCodec {
  SyncCodec(this._db);

  final DatabaseExecutor _db;

  final Map<String, Map<String, String>> _references =
      <String, Map<String, String>>{};

  /// Pointers already resolved, both ways round.
  ///
  /// Ten orders' worth of stock movements all point at the same dozen
  /// ingredients, and asking the database which uid each one has — ten times
  /// over, once per movement — was most of the work of telling the other till
  /// anything. A row's id and its uid are fixed for the life of the row, so
  /// the answer is worth keeping.
  ///
  /// Only answers are kept, never the absence of one: a pointer to something
  /// that has not arrived yet must be asked about again on the next pass, or
  /// an order line would wait for its order for ever. [forgetPointers] drops
  /// the lot, for the one case where a row's uid really does change — when
  /// two tills turn out to have made the same row and one adopts the other's.
  final Map<String, String> _uids = <String, String>{};
  final Map<String, int> _ids = <String, int>{};

  /// Forgets resolved pointers, after something has changed a row's uid.
  void forgetPointers() {
    _uids.clear();
    _ids.clear();
  }

  /// Column → the table it points at, for one table.
  Future<Map<String, String>> referencesOf(String table) async {
    final Map<String, String>? known = _references[table];
    if (known != null) return known;

    final List<Map<String, Object?>> keys = await _db.rawQuery(
      'PRAGMA foreign_key_list($table)',
    );
    return _references[table] = <String, String>{
      for (final Map<String, Object?> key in keys)
        // Only a pointer to a row id needs translating. A reference to a
        // business key — `payments.method` naming `payment_methods.code` —
        // already means the same thing on both tills, and swapping it for
        // a uid would lose the one word the receipt prints.
        if (key['to'] == null || key['to'] == 'id')
          key['from']! as String: key['table']! as String,
    };
  }

  /// A row as it should travel: no local id, and pointers given by name.
  ///
  /// A pointer to a row that has no uid — nothing in the shop should, but a
  /// database restored from an old backup might — is sent as null rather
  /// than as a number that would land on an unrelated row at the other end.
  Future<Map<String, Object?>> encode(
    String table,
    Map<String, Object?> row,
  ) async {
    final Map<String, String> references = await referencesOf(table);
    final Map<String, Object?> out = <String, Object?>{};

    for (final MapEntry<String, Object?> column in row.entries) {
      if (column.key == 'id' || column.key == 'uid') continue;
      final String? points = references[column.key];
      if (points == null || column.value == null) {
        out[column.key] = column.value;
        continue;
      }
      out['${column.key}@'] = await _uidOf(points, column.value! as int);
    }
    return out;
  }

  /// The reverse: pointers resolved to this till's own ids.
  ///
  /// Returns null when something it points at has not arrived yet, which is
  /// the caller's signal to hold the change rather than write a row that
  /// points nowhere.
  Future<Map<String, Object?>?> decode(
    String table,
    Map<String, Object?> data,
  ) async {
    final Map<String, Object?> out = <String, Object?>{};

    for (final MapEntry<String, Object?> column in data.entries) {
      if (!column.key.endsWith('@')) {
        out[column.key] = column.value;
        continue;
      }
      final String name = column.key.substring(0, column.key.length - 1);
      final String? uid = column.value as String?;
      if (uid == null) {
        out[name] = null;
        continue;
      }
      final Map<String, String> references = await referencesOf(table);
      final int? id = await _idOf(references[name]!, uid);
      if (id == null) return null;
      out[name] = id;
    }
    return out;
  }

  Future<String?> _uidOf(String table, int id) async {
    final String key = '$table/$id';
    final String? known = _uids[key];
    if (known != null) return known;
    final List<Map<String, Object?>> rows = await _db.query(
      table,
      columns: <String>['uid'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final String? uid = rows.first['uid'] as String?;
    if (uid != null) _uids[key] = uid;
    return uid;
  }

  Future<int?> _idOf(String table, String uid) async {
    final String key = '$table/$uid';
    final int? known = _ids[key];
    if (known != null) return known;
    final List<Map<String, Object?>> rows = await _db.query(
      table,
      columns: <String>['id'],
      where: 'uid = ?',
      whereArgs: <Object?>[uid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final int? id = rows.first['id'] as int?;
    if (id != null) _ids[key] = id;
    return id;
  }
}
