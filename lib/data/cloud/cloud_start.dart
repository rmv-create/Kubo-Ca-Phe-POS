import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'firebase_options.dart';

/// Starting Firebase, without making anybody wait for it.
///
/// Reaching Firebase needs the network, and the network is the one thing a
/// home-based shop in Bataan cannot count on. Waiting for it before the
/// first frame means a phone with no signal shows a white screen instead of
/// a POS — which is the worst possible trade, because a till that has
/// already been let into a shop needs the cloud for nothing at all.
///
/// So the app starts it and walks away. Anything that genuinely needs the
/// cloud — signing in, letting a phone in, syncing — waits on [ready] at the
/// moment it needs it, and gives up after a while rather than hanging.
abstract final class CloudStart {
  static Future<bool>? _started;

  /// Begins connecting. Safe to call more than once; only the first counts.
  static void begin() => _started ??= _connect();

  /// Resolves true once Firebase is up, false if it could not be reached.
  ///
  /// Never throws and never waits for ever: a caller gets an answer inside
  /// [patience] and can tell the owner something true.
  static Future<bool> ready({
    Duration patience = const Duration(seconds: 15),
  }) async {
    begin();
    try {
      return await _started!.timeout(patience);
    } on Object {
      return false;
    }
  }

  static Future<bool> _connect() async {
    try {
      await Firebase.initializeApp(options: KuboFirebase.options);
      return true;
    } on Object catch (error) {
      debugPrint('Kubo is running without the cloud: $error');
      return false;
    }
  }
}
