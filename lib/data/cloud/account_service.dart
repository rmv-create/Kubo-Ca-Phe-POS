import 'package:firebase_auth/firebase_auth.dart';

import 'cloud_start.dart';

/// The owner's account: an email and a password she chooses, held by
/// Firebase rather than by this app.
///
/// This is what makes the shop hers rather than the phone's. Before it, the
/// app's six-digit PIN locked one browser's own copy of the data and nothing
/// else: a second phone opening the same link got a blank shop, and there was
/// no way to let a barista into *her* shop rather than into a new one.
///
/// A barista never uses this. Her phone signs in anonymously — an identity
/// the device is given, which proves nothing on its own — and is let into the
/// shop by an invite the owner reads out. What the owner is really doing when
/// she signs in here is proving she can come back on a different phone.
class AccountService {
  AccountService({FirebaseAuth? auth}) : _auth = auth;

  final FirebaseAuth? _auth;

  /// Null when Firebase was never initialised — a test, or a build with no
  /// cloud configured. Everything below then reports "not available" rather
  /// than throwing, so the POS still opens.
  FirebaseAuth? get _firebase {
    if (_auth != null) return _auth;
    try {
      return FirebaseAuth.instance;
    } on Object {
      return null;
    }
  }

  bool get isAvailable => _firebase != null;

  /// The signed-in owner, or null. An anonymous device is *not* an owner.
  AccountUser? get current {
    final User? user = _firebase?.currentUser;
    if (user == null || user.isAnonymous) return null;
    return AccountUser(uid: user.uid, email: user.email ?? '');
  }

  /// Any signed-in identity at all, anonymous included. This is what the
  /// Firestore rules match a till document against.
  String? get deviceUid => _firebase?.currentUser?.uid;

  Stream<AccountUser?> changes() =>
      _firebase?.authStateChanges().map((User? user) {
        if (user == null || user.isAnonymous) return null;
        return AccountUser(uid: user.uid, email: user.email ?? '');
      }) ??
      const Stream<AccountUser?>.empty();

  /// Makes the owner's account. The shop is created separately, once this
  /// succeeds, so a half-made account never leaves a shop with no owner.
  Future<AccountOutcome> createAccount({
    required String email,
    required String password,
  }) => _attempt(
    () async => _firebase!.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    ),
  );

  Future<AccountOutcome> signIn({
    required String email,
    required String password,
  }) => _attempt(
    () async => _firebase!.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    ),
  );

  /// Signs the device in without an account, which is how a barista's phone
  /// identifies itself while she types an invite.
  Future<bool> signInAsDevice() async {
    await CloudStart.ready();
    final FirebaseAuth? auth = _firebase;
    if (auth == null) return false;
    try {
      if (auth.currentUser == null) await auth.signInAnonymously();
      return auth.currentUser != null;
    } on Object {
      return false;
    }
  }

  /// Removes the account that was just made, after it turned out not to be
  /// allowed to open a shop.
  ///
  /// Without this, every refused attempt would leave a dead account in her
  /// Firebase list for her to wonder about. It works because the account is
  /// signed in at that moment — a few seconds later Firebase would ask it to
  /// sign in again first, which is why this is only ever called straight
  /// after a refusal.
  Future<void> discardCurrentAccount() async {
    try {
      await _firebase?.currentUser?.delete();
    } on Object {
      await signOut();
    }
  }

  Future<void> sendPasswordReset(String email) async =>
      _firebase?.sendPasswordResetEmail(email: email.trim());

  Future<void> signOut() async => _firebase?.signOut();

  Future<AccountOutcome> _attempt(Future<UserCredential> Function() run) async {
    await CloudStart.ready();
    if (_firebase == null) {
      return const AccountOutcome.failed(
        'This phone cannot reach the shop account. Check the connection and '
        'try again.',
      );
    }
    try {
      final UserCredential credential = await run();
      final User? user = credential.user;
      if (user == null) {
        return const AccountOutcome.failed('Signing in did not finish.');
      }
      return AccountOutcome.ok(
        AccountUser(uid: user.uid, email: user.email ?? ''),
      );
    } on FirebaseAuthException catch (error) {
      return AccountOutcome.failed(_readable(error.code));
    } on Object {
      return const AccountOutcome.failed(
        'Could not reach the shop account. Check the connection.',
      );
    }
  }

  /// Firebase's codes, in words she can act on.
  static String _readable(String code) => switch (code) {
    'invalid-email' => 'That does not look like an email address.',
    'user-disabled' => 'That account has been switched off.',
    'user-not-found' ||
    'wrong-password' ||
    'invalid-credential' => 'That email and password do not match an account.',
    'email-already-in-use' =>
      'There is already an account with that email. Sign in instead.',
    'weak-password' =>
      'That password is too short. Use at least six '
          'characters.',
    'too-many-requests' => 'Too many tries. Wait a few minutes and try again.',
    'network-request-failed' => 'No connection. Find signal and try again.',
    'operation-not-allowed' =>
      'Email sign-in has not been switched on for this shop yet.',
    _ => 'Could not sign in. Please try again.',
  };
}

class AccountUser {
  const AccountUser({required this.uid, required this.email});

  final String uid;
  final String email;
}

/// What happened, in a form the screen can show without knowing Firebase.
class AccountOutcome {
  const AccountOutcome.ok(AccountUser this.user) : problem = null;
  const AccountOutcome.failed(String this.problem) : user = null;

  final AccountUser? user;
  final String? problem;

  bool get succeeded => user != null;
}
