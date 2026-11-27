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
/// The shop would not take a write.
///
/// Named here, away from any one post box, so the rule about what to do
/// with a refusal can be written and tested without a shop to be refused
/// by.
class RefusedByTheShop implements Exception {
  const RefusedByTheShop();

  @override
  String toString() => 'permission-denied';
}

/// Puts changes into an append-only log, a batch at a time, stepping over
/// the ones that are already in it.
///
/// The log refuses a second write to an entry, and a batch is all or
/// nothing, so one change that is already up there takes the whole batch
/// down — and it stays up there, so every round afterwards dies in the
/// same place while the queue behind it grows without limit. A till posts
/// a batch, loses signal before it can write down that it did, and is
/// deadlocked for good. The only sign of it is a refusal, which reads
/// exactly like a till that was never let into the shop.
///
/// So a refused batch is tried again one change at a time, and a refusal
/// there is forgiven only once the entry has been found in the log under
/// this change's own name. Anything else is a till being refused outright
/// and must be reported: a change wrongly written off as sent is a sale
/// the other phone never hears about.
class PostingToTheLog {
  const PostingToTheLog({
    required this.commit,
    required this.postOne,
    required this.alreadyThere,
    this.lotSize = 400,
  });

  /// Writes a whole lot at once, throwing [RefusedByTheShop] if the shop
  /// will not take any one of them.
  final Future<void> Function(List<SyncChange> lot) commit;

  /// Writes a single change, throwing [RefusedByTheShop] if refused.
  final Future<void> Function(SyncChange change) postOne;

  /// Whether the log already holds an entry under this name.
  final Future<bool> Function(String changeId) alreadyThere;

  final int lotSize;

  Future<void> call(List<SyncChange> changes) async {
    for (int from = 0; from < changes.length; from += lotSize) {
      final List<SyncChange> lot = changes.skip(from).take(lotSize).toList();
      try {
        await commit(lot);
      } on RefusedByTheShop {
        await _oneByOne(lot);
      }
    }
  }

  Future<void> _oneByOne(List<SyncChange> lot) async {
    for (final SyncChange change in lot) {
      try {
        await postOne(change);
      } on RefusedByTheShop {
        if (!await alreadyThere(change.changeId)) rethrow;
      }
    }
  }
}

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

  /// The sign-in id this phone is holding right now, if any. The shop knows
  /// a till by this and by nothing else.
  String? get identity;
}

/// What came back, and where to carry on from.
class SyncFetch {
  const SyncFetch({required this.changes, required this.cursor});

  const SyncFetch.nothing(this.cursor) : changes = const <SyncChange>[];

  final List<SyncChange> changes;

  /// Null means "nothing new, keep the cursor you had".
  final String? cursor;
}
