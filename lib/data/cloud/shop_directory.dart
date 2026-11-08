import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'cloud_start.dart';

/// Who is allowed into a shop.
///
/// Separate from the sync transport on purpose. The transport carries
/// changes between tills that are already trusted; this decides which tills
/// those are. Mixing the two would mean the thing that moves the data also
/// decides who may have it.
///
/// The shape in Firestore:
///
/// ```text
///   shops/{shopId}              owner_uid, opened_at
///   shops/{shopId}/tills/{uid}  label, role, device_id, joined_at
///   invites/{code}              shop_id, expires_at, created_by
///   owners/{uid}                shop_id
/// ```
///
/// An invite is a document of its own rather than a field on the shop so
/// that a phone holding nothing but the code can find the shop. Knowing a
/// shop's id is not a way in; knowing a live invite is, for ten minutes.
class ShopDirectory {
  ShopDirectory({FirebaseFirestore? firestore}) : _injected = firestore;

  final FirebaseFirestore? _injected;

  FirebaseFirestore? get _db {
    if (_injected != null) return _injected;
    try {
      return FirebaseFirestore.instance;
    } on Object {
      return null;
    }
  }

  /// Letters and digits that survive being read aloud across a counter.
  /// No O or 0, no I or 1, no S or 5 — the three pairs people mishear.
  static const String _alphabet = 'ABCDEFGHJKLMNPQRTUVWXYZ2346789';

  /// A fresh shop id. Long and random: it is never typed, only carried.
  static String newShopId() {
    final Random random = Random.secure();
    return List<String>.generate(
      32,
      (_) => '0123456789abcdef'[random.nextInt(16)],
    ).join();
  }

  /// An invite, as `K7PQ-M39X`.
  ///
  /// Eight characters from thirty, which is about a hundred thousand times
  /// more to guess at than six digits would be — and it only lives for ten
  /// minutes. Short enough to say down the phone, long enough that saying it
  /// is the only way to get it.
  static String newInvite() {
    final Random random = Random.secure();
    final String raw = List<String>.generate(
      8,
      (_) => _alphabet[random.nextInt(_alphabet.length)],
    ).join();
    return '${raw.substring(0, 4)}-${raw.substring(4)}';
  }

  /// Hyphens, spaces and lower case are how people type; the stored code has
  /// none of them.
  static String tidy(String code) =>
      code.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  DocumentReference<Map<String, Object?>> _shop(String shopId) =>
      _db!.collection('shops').doc(shopId);

  /// Opens a new shop, owned by the account signing in right now.
  Future<void> createShop({
    required String shopId,
    required String ownerUid,
    required String deviceId,
    required String label,
  }) async {
    await CloudStart.ready();
    // The owner's own till first: the rules let the first one in unasked,
    // and only while the shop does not exist yet.
    await _shop(shopId).collection('tills').doc(ownerUid).set(<String, Object?>{
      'label': label,
      'role': 'owner',
      'device_id': deviceId,
      'joined_at': FieldValue.serverTimestamp(),
    });
    await _shop(shopId).set(<String, Object?>{
      'owner_uid': ownerUid,
      'opened_at': FieldValue.serverTimestamp(),
    });
    // So that she can sign in on a phone that knows nothing and still be
    // told which shop is hers. Only she can read it.
    await _db!.collection('owners').doc(ownerUid).set(<String, Object?>{
      'shop_id': shopId,
    });
  }

  /// The shop belonging to this account, or null if it never opened one.
  Future<String?> shopOwnedBy(String uid) async {
    await CloudStart.ready();
    final FirebaseFirestore? db = _db;
    if (db == null) return null;
    try {
      final DocumentSnapshot<Map<String, Object?>> doc = await db
          .collection('owners')
          .doc(uid)
          .get();
      return doc.data()?['shop_id'] as String?;
    } on FirebaseException {
      return null;
    }
  }

  /// Writes an invite that is good for ten minutes.
  Future<void> offerInvite({
    required String shopId,
    required String code,
    required DateTime until,
    required String byUid,
  }) async {
    await _db!.collection('invites').doc(tidy(code)).set(<String, Object?>{
      'shop_id': shopId,
      'created_by': byUid,
      'expires_at': Timestamp.fromDate(until),
    });
  }

  /// Which shop an invite opens, or null if it is wrong or has run out.
  Future<String?> shopForInvite(String code) async {
    await CloudStart.ready();
    final FirebaseFirestore? db = _db;
    if (db == null) return null;
    final String key = tidy(code);
    if (key.isEmpty) return null;
    try {
      final DocumentSnapshot<Map<String, Object?>> doc = await db
          .collection('invites')
          .doc(key)
          .get();
      final Map<String, Object?>? data = doc.data();
      if (data == null) return null;
      final Timestamp? expires = data['expires_at'] as Timestamp?;
      if (expires == null || expires.toDate().isBefore(DateTime.now())) {
        return null;
      }
      return data['shop_id'] as String?;
    } on FirebaseException {
      return null;
    }
  }

  /// Takes the invite and becomes a till of that shop.
  Future<bool> join({
    required String shopId,
    required String code,
    required String uid,
    required String deviceId,
    required String label,
  }) async {
    try {
      await _shop(shopId).collection('tills').doc(uid).set(<String, Object?>{
        'label': label,
        'role': 'barista',
        'device_id': deviceId,
        // Checked against the invite by the rules. Written once to get in,
        // and of no use to anybody afterwards.
        'code': tidy(code),
        'joined_at': FieldValue.serverTimestamp(),
      });
      return true;
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') return false;
      rethrow;
    }
  }

  /// Every phone the owner has let in.
  Future<List<AdmittedTill>> tills(String shopId) async {
    final QuerySnapshot<Map<String, Object?>> snapshot = await _shop(
      shopId,
    ).collection('tills').get();
    return <AdmittedTill>[
      for (final QueryDocumentSnapshot<Map<String, Object?>> doc
          in snapshot.docs)
        AdmittedTill(
          uid: doc.id,
          label: doc.data()['label'] as String? ?? 'A phone',
          role: doc.data()['role'] as String? ?? 'barista',
          joinedAt: (doc.data()['joined_at'] as Timestamp?)?.toDate(),
          lastSeenAt: (doc.data()['last_seen_at'] as Timestamp?)?.toDate(),
        ),
    ];
  }

  /// Shuts a phone out — lost, sold, or the barista has left.
  ///
  /// What it already holds is already on it; this stops it being told
  /// anything more, and stops anything it says being heard.
  Future<void> removeTill({required String shopId, required String uid}) async {
    await _shop(shopId).collection('tills').doc(uid).delete();
  }

  /// Withdraws an invite that has not been used.
  Future<void> cancelInvite(String code) async {
    await _db?.collection('invites').doc(tidy(code)).delete();
  }
}

/// A phone the owner has let in.
class AdmittedTill {
  const AdmittedTill({
    required this.uid,
    required this.label,
    required this.role,
    this.joinedAt,
    this.lastSeenAt,
  });

  final String uid;
  final String label;
  final String role;
  final DateTime? joinedAt;
  final DateTime? lastSeenAt;

  bool get isOwner => role == 'owner';
}
