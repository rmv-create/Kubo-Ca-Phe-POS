import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Somewhere for a change that has arrived before the row it belongs to.
///
/// A change can only be applied once the thing it points at is here: an
/// order's line needs its order, a customer's habit needs the customer. The
/// log is a stream of rows rather than a tree, so one can easily overtake
/// the other — and it is read a page at a time, so the parent may be on the
/// next page, or the one after.
///
/// Until now the till held such a change for the length of one round and
/// then forgot it, while the cursor moved past it for ever. The parent would
/// arrive on the next page and the thing that belonged to it was already
/// gone: an order on one phone that never appeared on the other, no error
/// anywhere, nothing to find.
///
/// So they are written down instead. Every round starts by trying the ones
/// it is still holding, and only what still has nothing to hang on stays
/// behind.
///
/// It is this device's own notebook: never sent anywhere, and no outbox
/// triggers, because telling the other till what this one is waiting for
/// would be telling it about its own changes.
class M023NothingIsLostWaiting extends Migration {
  const M023NothingIsLostWaiting();

  @override
  int get version => 23;

  @override
  String get name => 'nothing_is_lost_waiting';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE sync_waiting (
        change_id  TEXT PRIMARY KEY,
        payload    TEXT NOT NULL,
        first_seen TEXT NOT NULL,
        tries      INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }
}
