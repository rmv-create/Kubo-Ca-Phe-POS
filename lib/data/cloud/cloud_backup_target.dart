import 'dart:io';

import 'package:meta/meta.dart';

/// Somewhere off the phone that a backup can be sent, without being asked.
///
/// The share sheet already covers "send a copy by hand". This is the other
/// thing: a place the app can put the closing backup every night whether or
/// not anyone remembers to.
abstract interface class CloudBackupTarget {
  /// What to call it on screen — "Google Drive".
  String get label;

  /// Whether the app has been given an account to upload to.
  Future<bool> isConnected();

  /// The signed-in account, for showing which Drive the files are going to.
  Future<String?> accountLabel();

  /// Asks the owner to sign in and grant access. Must be called from a tap:
  /// the platforms require the request to come from a user interaction.
  Future<bool> connect();

  Future<void> disconnect();

  /// Sends one file. Throws [CloudBackupException] if it could not be done.
  Future<void> upload(File file, {required String name});
}

/// Anything that stopped a backup reaching the cloud, in words she can act on.
@immutable
class CloudBackupException implements Exception {
  const CloudBackupException(this.message, {this.isAuthProblem = false});

  final String message;

  /// True when the fix is to sign in again rather than to try later.
  final bool isAuthProblem;

  @override
  String toString() => message;
}
