import 'package:firebase_core/firebase_core.dart';

/// The owner's own Firebase project, where the two tills meet.
///
/// These values are not secret. Firebase web configuration is public by
/// design — it is in the page source of every Firebase site there is — and
/// what actually guards the shop's records is the security rules in
/// `firestore.rules`: a till must be signed in *and* be one she has let in
/// before it can read or write a single row.
///
/// Created on 8 November 2026 in the project `kubo-ca-phe-pos`.
abstract final class KuboFirebase {
  static const FirebaseOptions options = FirebaseOptions(
    apiKey: 'AIzaSyDfQheRnc2f25PMMmnTKeLhwveLjwfepbE',
    authDomain: 'kubo-ca-phe-pos.firebaseapp.com',
    projectId: 'kubo-ca-phe-pos',
    storageBucket: 'kubo-ca-phe-pos.firebasestorage.app',
    messagingSenderId: '406688840107',
    appId: '1:406688840107:web:1be60191adf0468ce4faee',
  );

  /// Whether this build has somewhere to sync to at all.
  static bool get isConfigured => options.apiKey.isNotEmpty;
}
