import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'sync_change.dart';
import 'sync_transport.dart';

/// The postbox, as a Firestore collection.
///
/// One document per change, under the shop. Every till writes its own and
/// reads everyone's; nothing is ever updated or deleted, so two tills
/// writing at the same moment cannot tread on each other — the collection
/// is a log, not a copy of the shop.
///
/// Firestore was chosen for one property above the rest: it holds writes
/// that cannot go out yet and sends them when the signal comes back, which
/// is most mornings in a home-based shop.
class FirestoreSyncTransport implements SyncTransport {
  FirestoreSyncTransport({
    required this.shopId,
    required this.deviceId,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? FirebaseAuth.instance;

  /// Which shop's log this is. Long and random, made once by the first
  /// till and carried to the second in her export file.
  final String shopId;
  final String deviceId;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  CollectionReference<Map<String, Object?>> get _changes =>
      _db.collection('shops').doc(shopId).collection('changes');

  @override
  Future<bool> isReady() async {
    if (shopId.isEmpty) return false;
    // Signing in is the account's business, not the postbox's. By the time
    // a till is syncing it has already been let into the shop, so if there
    // is no identity here something earlier went wrong and the honest
    // answer is "not ready" rather than quietly making a new one.
    return _auth.currentUser != null;
  }

  @override
  Future<void> publish(List<SyncChange> changes) async {
    if (changes.isEmpty) return;

    // In batches, because Firestore takes 500 writes at a time and a till
    // that has been offline all day will have more than that.
    for (int from = 0; from < changes.length; from += 400) {
      final WriteBatch batch = _db.batch();
      for (final SyncChange change in changes.skip(from).take(400)) {
        batch.set(_changes.doc(change.changeId), <String, Object?>{
          ...change.toJson(),
          // The server's clock, not the till's: two tills' clocks disagree,
          // and this is only ever used to ask "what is new since I last
          // looked", never to decide who wins.
          'posted_at': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    }
  }

  @override
  Future<SyncFetch> fetch({String? afterCursor, int limit = 500}) async {
    Query<Map<String, Object?>> query = _changes
        .orderBy('posted_at')
        .limit(limit);
    if (afterCursor != null) {
      query = query.startAfter(<Object?>[
        Timestamp.fromMicrosecondsSinceEpoch(int.parse(afterCursor)),
      ]);
    }

    final QuerySnapshot<Map<String, Object?>> snapshot = await query.get();
    if (snapshot.docs.isEmpty) return SyncFetch.nothing(afterCursor);

    final List<SyncChange> changes = <SyncChange>[];
    String? cursor = afterCursor;
    for (final QueryDocumentSnapshot<Map<String, Object?>> doc
        in snapshot.docs) {
      final Map<String, Object?> data = doc.data();
      final Object? posted = data['posted_at'];
      // A document written moments ago may reach us before the server has
      // stamped it. Leaving the cursor where it is means we see it again
      // next time, which costs one read and never loses a change.
      if (posted is! Timestamp) continue;
      cursor = '${posted.microsecondsSinceEpoch}';
      if (data['device_id'] == deviceId) continue;
      changes.add(SyncChange.fromJson(data));
    }
    return SyncFetch(changes: changes, cursor: cursor);
  }

  @override
  Future<void> heartbeat({required String label}) async {
    // Keyed by the sign-in id, because that is the name the rules know this
    // phone by. `deviceId` is the sync engine's own name for it and means
    // nothing to Firestore.
    final String? uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _db
        .collection('shops')
        .doc(shopId)
        .collection('tills')
        .doc(uid)
        .set(<String, Object?>{
          'label': label,
          'device_id': deviceId,
          'last_seen_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }
}
