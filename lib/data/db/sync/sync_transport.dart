import 'sync_change.dart';

/// Somewhere the tills leave their changes for each other.
///
/// Kept to four methods, and deliberately ignorant of Firebase: everything
/// that decides whether a merge is correct lives in [SyncEngine] and is
/// tested without a network. This is only the postbox.
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

  /// Makes this till the shop's first one. Only works while there is no
  /// shop there: the second till has to be let in instead.
  Future<void> openShop({required String label});

  /// Shows a code for ten minutes so another till can be let in.
  Future<void> offerCode(String code, DateTime until);

  /// Asks to be let in with the code the other till is showing.
  ///
  /// Returns false when the code is wrong or has run out, which is a thing
  /// she can fix by looking at the other till again — not an error.
  Future<bool> joinWithCode(String code, {required String label});

  /// The other tills, and when each was last heard from.
  Future<List<TillPresence>> tills();
}

/// Another till, as this one last heard of it.
class TillPresence {
  const TillPresence({
    required this.deviceId,
    required this.label,
    this.lastSeenAt,
  });

  final String deviceId;
  final String label;
  final DateTime? lastSeenAt;
}

/// What came back, and where to carry on from.
class SyncFetch {
  const SyncFetch({required this.changes, required this.cursor});

  const SyncFetch.nothing(this.cursor) : changes = const <SyncChange>[];

  final List<SyncChange> changes;

  /// Null means "nothing new, keep the cursor you had".
  final String? cursor;
}
