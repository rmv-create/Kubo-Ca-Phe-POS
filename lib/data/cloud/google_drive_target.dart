import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';

import 'cloud_backup_target.dart';
import 'google_drive_api.dart';

/// Google Drive as a place the closing backup goes by itself.
///
/// The sign-in is the owner's own Google account. The app asks for one
/// scope, `drive.file`, which can only see files the app itself created: it
/// cannot read anything else in her Drive, and it needs no review by Google.
///
/// The client id comes from the build rather than the code, because it is
/// per-project and hers:
///
///     flutter build ipa --dart-define=GOOGLE_CLIENT_ID=<id>.apps.googleusercontent.com
///
/// See `docs/google_drive_backup.md` for the one-time setup.
class GoogleDriveTarget implements CloudBackupTarget {
  GoogleDriveTarget({GoogleSignIn? signIn, GoogleDriveApi? api})
    : _signIn = signIn ?? GoogleSignIn.instance {
    _api = api ?? GoogleDriveApi(accessToken: _accessToken);
  }

  static const String clientId = String.fromEnvironment('GOOGLE_CLIENT_ID');

  /// Where the backups land in her Drive.
  static const String folderName = 'Kubo Cà Phê backups';

  final GoogleSignIn _signIn;
  late final GoogleDriveApi _api;

  bool _initialised = false;
  GoogleSignInAccount? _account;
  String? _folderId;

  @override
  String get label => 'Google Drive';

  /// Whether this build was given a client id at all.
  static bool get isAvailable => clientId.isNotEmpty;

  Future<void> _initialise() async {
    if (_initialised) return;
    await _signIn.initialize(clientId: clientId.isEmpty ? null : clientId);
    _initialised = true;
    // Picks the account back up after a restart without asking her again.
    _account ??= await _signIn.attemptLightweightAuthentication();
  }

  @override
  Future<bool> isConnected() async {
    if (!isAvailable) return false;
    await _initialise();
    return _account != null;
  }

  @override
  Future<String?> accountLabel() async {
    if (!await isConnected()) return null;
    return _account?.email;
  }

  @override
  Future<bool> connect() async {
    if (!isAvailable) {
      throw const CloudBackupException(
        'This copy of Kubo was built without a Google client id, so it '
        'cannot sign in to Drive.',
      );
    }
    await _initialise();
    try {
      if (_signIn.supportsAuthenticate()) {
        _account = await _signIn.authenticate();
      }
      final GoogleSignInAccount? account = _account;
      if (account == null) return false;

      // Signing in and granting access are two separate things now, and the
      // second one has to come from a tap, which this is.
      await account.authorizationClient.authorizeScopes(<String>[
        GoogleDriveApi.scope,
      ]);
      return true;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) return false;
      throw CloudBackupException('Google refused the sign-in. ${error.code}');
    }
  }

  @override
  Future<void> disconnect() async {
    await _initialise();
    _account = null;
    _folderId = null;
    await _signIn.disconnect();
  }

  @override
  Future<void> upload(File file, {required String name}) async {
    if (!await isConnected()) {
      throw const CloudBackupException(
        'Kubo is not signed in to Google Drive.',
        isAuthProblem: true,
      );
    }
    _folderId ??= await _api.folderNamed(folderName);
    await _api.uploadFile(
      folderId: _folderId!,
      name: name,
      bytes: await file.readAsBytes(),
    );
  }

  /// A token for the one scope, without prompting.
  ///
  /// Null when the grant has lapsed, which surfaces as "connect the account
  /// again" rather than as a silent failure to back anything up.
  Future<String?> _accessToken() async {
    await _initialise();
    final GoogleSignInAccount? account = _account;
    if (account == null) return null;
    final GoogleSignInClientAuthorization? authorization = await account
        .authorizationClient
        .authorizationForScopes(<String>[GoogleDriveApi.scope]);
    return authorization?.accessToken;
  }
}
