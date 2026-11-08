import 'sync_change.dart';

/// Somewhere the tills leave their changes for each other.
///
/// Four methods, and deliberately ignorant of Firebase: everything that
/// decides whether a merge is correct lives in [SyncEngine] and is tested
/// without a network. This is only the postbox.
///
/// Who is allowed to use the postbox is not its business — that is
/// `ShopDirectory`. The thing that moves the data should not also be the
/// thing that decides who may have it.
abstract interface class SyncTransport {
  /// True once this till has somewhere to post to and is allowed to.
  Future<bool> isReady();

  /// Puts this till's changes where the others will see them.
  Future<void> publish(List<SyncChange> changes);

  /// Everything posted since [afterCursor], and a cursor to ask from next
  /// time. The cursor is the transport's own business; the engine only
  /// keeps it and hands it back.
  Future<SyncFetch> fetch({String? afterCursor, int limit});

  /// Says hello, so the other till can show when this one was last seen.
  Future<void> heartbeat({required String label});
}

/// What came back, and where to carry on from.
class SyncFetch {
  const SyncFetch({required this.changes, required this.cursor});

  const SyncFetch.nothing(this.cursor) : changes = const <SyncChange>[];

  final List<SyncChange> changes;

  /// Null means "nothing new, keep the cursor you had".
  final String? cursor;
}
