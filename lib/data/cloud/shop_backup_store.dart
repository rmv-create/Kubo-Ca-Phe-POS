import 'dart:typed_data';

/// One backup, as the cloud knows it.
class CloudBackup {
  const CloudBackup({
    required this.day,
    required this.takenAt,
    required this.bytes,
    required this.device,
  });

  /// The business day it closed, `2026-11-08`. One backup per day: closing
  /// twice replaces the first rather than filling her storage with
  /// near-identical copies.
  final String day;
  final DateTime takenAt;

  /// Size on the wire, after squeezing.
  final int bytes;
  final String device;

  String get sizeLabel {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Somewhere the nightly copy of the shop goes.
///
/// Kept behind an interface so the thing that decides *when* to back up is
/// testable without a network, and so the place it goes can change without
/// the rest of the app noticing.
abstract interface class ShopBackupStore {
  /// True when there is somewhere to put it and we are allowed to.
  Future<bool> isReady();

  /// Puts the day's copy up, replacing that day's if it is already there.
  Future<void> put({
    required String shopId,
    required String day,
    required Uint8List data,
    required String device,
  });

  /// What is up there, newest first.
  Future<List<CloudBackup>> list(String shopId);

  /// Fetches one back down.
  Future<Uint8List?> get({required String shopId, required String day});

  /// Removes one.
  Future<void> remove({required String shopId, required String day});
}
