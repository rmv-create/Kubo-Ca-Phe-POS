import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../core/time/clock.dart';
import '../../data/cloud/shop_backup_store.dart';
import '../../data/db/database_archive.dart';
import '../entities/business_settings.dart';
import '../repositories/settings_repository.dart';

/// Puts a copy of the whole shop somewhere that is not the phone, once a
/// day, without being asked.
///
/// The shop lives in one browser on one phone. Everything else about the
/// app is built so that a lost signal costs nothing; a lost phone costs
/// everything, and this is the only thing standing between her and that.
///
/// Three rules, and they are all about not being annoying:
///
///  * **Once a day.** The business day, not the calendar day, so closing at
///    one in the morning still counts as the night before.
///  * **Never in the way.** It never throws. A round that fails is written
///    down and tried again next time; it never stops her closing the day or
///    taking the next order.
///  * **Old ones go.** Thirty days is kept. A year of daily copies of a
///    growing database would quietly fill her free storage, and the backup
///    that matters is almost always last night's.
class NightlyBackupService {
  NightlyBackupService({
    required DatabaseArchive archive,
    required SettingsRepository settings,
    required Clock clock,
    ShopBackupStore? store,
  }) : _archive = archive,
       _settings = settings,
       _clock = clock,
       _store = store;

  final DatabaseArchive _archive;
  final SettingsRepository _settings;
  final Clock _clock;
  final ShopBackupStore? _store;

  /// How many nights are kept.
  static const int keepDays = 30;

  Future<String?> _shopId() async {
    final String? id = await _settings.readRaw(SettingKeys.syncShopId);
    return id == null || id.isEmpty ? null : id;
  }

  Future<String> _device() async =>
      await _settings.readRaw(SettingKeys.syncDeviceLabel) ?? 'A till';

  Future<String?> lastBackedUpDay() async =>
      _settings.readRaw(SettingKeys.cloudLastBackupDay);

  Future<String?> lastProblem() async {
    final String? raw = await _settings.readRaw(SettingKeys.cloudLastError);
    return raw == null || raw.isEmpty ? null : raw;
  }

  /// Whether today's copy is already safely off the phone.
  Future<bool> isDoneFor(String day) async => await lastBackedUpDay() == day;

  /// Sends the day's copy up, unless it already went.
  ///
  /// [force] sends it again even if it did — for the button that says "back
  /// up now", where being told "already done" is not what she wants.
  Future<BackupRound> run({
    required String day,
    bool force = false,
  }) async {
    final ShopBackupStore? store = _store;
    if (store == null) {
      return const BackupRound.skipped('This app has no cloud to back up to.');
    }

    final String? shopId = await _shopId();
    if (shopId == null) {
      return const BackupRound.skipped(
        'This shop has no owner yet, so there is nowhere of its own to put '
        'a backup. Manage → Phones in this shop.',
      );
    }

    if (!force && await isDoneFor(day)) {
      return const BackupRound.alreadyDone();
    }

    try {
      if (!await store.isReady()) {
        return await _failed(
          'No connection. Nothing is lost — it will go up next time.',
        );
      }

      final Uint8List squeezed = await _squeeze();
      await store.put(
        shopId: shopId,
        day: day,
        data: squeezed,
        device: await _device(),
      );

      await _settings.writeRaw(SettingKeys.cloudLastBackupDay, day);
      await _settings.writeRaw(
        SettingKeys.cloudLastUploadAt,
        _clock.now().toUtc().toIso8601String(),
      );
      await _settings.writeRaw(SettingKeys.cloudLastError, '');

      // Only after this night's is safely up. Pruning first would mean a
      // failed upload had cost her a copy she still had.
      final int removed = await _prune(store, shopId);
      return BackupRound.sent(bytes: squeezed.length, pruned: removed);
    } on Object catch (error) {
      return _failed(_readable(error));
    }
  }

  /// The whole shop as one squeezed blob.
  ///
  /// The export is SQL text, which compresses to about a tenth of itself —
  /// worth doing when it crosses a mobile connection every night and lands
  /// in a free storage allowance.
  Future<Uint8List> _squeeze() async {
    final String sql = await _archive.export();
    final List<int> raw = utf8.encode(sql);
    final List<int>? gzipped = GZipEncoder().encode(raw);
    return Uint8List.fromList(gzipped ?? raw);
  }

  /// Reads one back down and unsqueezes it.
  Future<String?> fetch(String day) async {
    final ShopBackupStore? store = _store;
    final String? shopId = await _shopId();
    if (store == null || shopId == null) return null;
    final Uint8List? data = await store.get(shopId: shopId, day: day);
    if (data == null) return null;
    return utf8.decode(GZipDecoder().decodeBytes(data));
  }

  Future<List<CloudBackup>> list() async {
    final ShopBackupStore? store = _store;
    final String? shopId = await _shopId();
    if (store == null || shopId == null) return <CloudBackup>[];
    try {
      if (!await store.isReady()) return <CloudBackup>[];
      return await store.list(shopId);
    } on Object {
      return <CloudBackup>[];
    }
  }

  Future<int> _prune(ShopBackupStore store, String shopId) async {
    final List<CloudBackup> all = await store.list(shopId);
    if (all.length <= keepDays) return 0;
    int removed = 0;
    for (final CloudBackup old in all.skip(keepDays)) {
      try {
        await store.remove(shopId: shopId, day: old.day);
        removed++;
      } on Object {
        // Storage she is not using is not worth failing a backup over.
      }
    }
    return removed;
  }

  Future<BackupRound> _failed(String why) async {
    await _settings.writeRaw(SettingKeys.cloudLastError, why);
    return BackupRound.failed(why);
  }

  static String _readable(Object error) {
    final String text = error.toString();
    if (text.contains('permission-denied')) {
      return 'This till is not allowed to write backups for this shop.';
    }
    if (text.contains('unavailable') || text.contains('network')) {
      return 'No connection. Nothing is lost — it will go up next time.';
    }
    if (text.contains('resource-exhausted')) {
      return 'The shop’s free storage is full. Older backups should be '
          'cleared out.';
    }
    return 'The backup could not be sent. It will be tried again next time.';
  }
}

/// What one round did.
class BackupRound {
  const BackupRound.sent({required this.bytes, required this.pruned})
    : outcome = BackupOutcome.sent,
      message = null;
  const BackupRound.alreadyDone()
    : outcome = BackupOutcome.alreadyDone,
      bytes = 0,
      pruned = 0,
      message = null;
  const BackupRound.failed(String this.message)
    : outcome = BackupOutcome.failed,
      bytes = 0,
      pruned = 0;
  const BackupRound.skipped(String this.message)
    : outcome = BackupOutcome.skipped,
      bytes = 0,
      pruned = 0;

  final BackupOutcome outcome;
  final int bytes;
  final int pruned;
  final String? message;

  bool get sent => outcome == BackupOutcome.sent;
}

enum BackupOutcome { sent, alreadyDone, failed, skipped }
