import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'cloud_start.dart';
import 'shop_backup_store.dart';

/// The nightly copy of the shop, kept in her own Firebase.
///
/// Google Drive would have been the obvious home for it, and for a phone app
/// it would be. From a web page it is not: the only free way to reach Drive
/// from a browser hands out an access token that dies within the hour and
/// cannot be renewed without somebody tapping through a Google window —
/// which, in an app saved to the home screen on an iPhone, opens in Safari
/// and often cannot hand the answer back. "Automatic" would have meant
/// "automatic until it quietly stopped", which is the worst thing a backup
/// can be.
///
/// Her Firebase project is already hers, already signed in, and already
/// reachable from the page. The backup goes there, by itself, every closing.
/// She can still save a file to Drive by hand whenever she likes, and the
/// Backup screen still presses her to.
///
/// The shape:
///
/// ```text
///   shops/{shopId}/backups/{day}            taken_at, bytes, parts, device
///   shops/{shopId}/backups/{day}/parts/{n}  data
/// ```
///
/// Split into parts because a Firestore document holds a megabyte and a
/// year of a busy shop will not fit in one.
class FirestoreBackupStore implements ShopBackupStore {
  FirestoreBackupStore({FirebaseFirestore? firestore, FirebaseAuth? auth})
    : _injected = firestore,
      _injectedAuth = auth;

  final FirebaseFirestore? _injected;
  final FirebaseAuth? _injectedAuth;

  /// Comfortably under Firestore's one-megabyte document limit, leaving room
  /// for the field names and the overhead of the encoding.
  static const int partBytes = 700 * 1024;

  FirebaseFirestore? get _db {
    if (_injected != null) return _injected;
    try {
      return FirebaseFirestore.instance;
    } on Object {
      return null;
    }
  }

  FirebaseAuth? get _auth {
    if (_injectedAuth != null) return _injectedAuth;
    try {
      return FirebaseAuth.instance;
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> isReady() async {
    await CloudStart.ready();
    return _db != null && _auth?.currentUser != null;
  }

  CollectionReference<Map<String, Object?>> _backups(String shopId) =>
      _db!.collection('shops').doc(shopId).collection('backups');

  @override
  Future<void> put({
    required String shopId,
    required String day,
    required Uint8List data,
    required String device,
  }) async {
    final DocumentReference<Map<String, Object?>> doc = _backups(shopId).doc(
      day,
    );

    // Last night's parts first. A shorter backup landing on top of a longer
    // one would otherwise leave the tail of the old one behind, and the two
    // spliced together are not a database.
    await _clearParts(doc);

    int index = 0;
    for (int from = 0; from < data.length; from += partBytes) {
      final int to = (from + partBytes).clamp(0, data.length);
      await doc.collection('parts').doc('$index').set(<String, Object?>{
        'data': Blob(Uint8List.sublistView(data, from, to)),
      });
      index++;
    }

    await doc.set(<String, Object?>{
      'taken_at': FieldValue.serverTimestamp(),
      'bytes': data.length,
      'parts': index,
      'device': device,
    });
  }

  @override
  Future<List<CloudBackup>> list(String shopId) async {
    final QuerySnapshot<Map<String, Object?>> snapshot = await _backups(shopId)
        .orderBy(FieldPath.documentId, descending: true)
        .limit(60)
        .get();
    return <CloudBackup>[
      for (final QueryDocumentSnapshot<Map<String, Object?>> doc
          in snapshot.docs)
        CloudBackup(
          day: doc.id,
          takenAt:
              (doc.data()['taken_at'] as Timestamp?)?.toDate() ??
              DateTime.fromMillisecondsSinceEpoch(0),
          bytes: (doc.data()['bytes'] as num?)?.toInt() ?? 0,
          device: doc.data()['device'] as String? ?? 'a till',
        ),
    ];
  }

  @override
  Future<Uint8List?> get({
    required String shopId,
    required String day,
  }) async {
    final DocumentSnapshot<Map<String, Object?>> head = await _backups(
      shopId,
    ).doc(day).get();
    final int? parts = (head.data()?['parts'] as num?)?.toInt();
    if (parts == null) return null;

    final BytesBuilder whole = BytesBuilder(copy: false);
    for (int i = 0; i < parts; i++) {
      final DocumentSnapshot<Map<String, Object?>> part = await _backups(shopId)
          .doc(day)
          .collection('parts')
          .doc('$i')
          .get();
      final Blob? blob = part.data()?['data'] as Blob?;
      // A missing part means a half-finished upload. Half a database is
      // worse than none, so say none.
      if (blob == null) return null;
      whole.add(blob.bytes);
    }
    return whole.toBytes();
  }

  @override
  Future<void> remove({required String shopId, required String day}) async {
    final DocumentReference<Map<String, Object?>> doc = _backups(shopId).doc(
      day,
    );
    await _clearParts(doc);
    await doc.delete();
  }

  Future<void> _clearParts(DocumentReference<Map<String, Object?>> doc) async {
    final QuerySnapshot<Map<String, Object?>> old = await doc
        .collection('parts')
        .get();
    for (final QueryDocumentSnapshot<Map<String, Object?>> part in old.docs) {
      await part.reference.delete();
    }
  }
}
