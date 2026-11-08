import 'dart:io';

import '../../core/time/clock.dart';
import '../../domain/entities/backup_entry.dart';
import '../../domain/entities/business_settings.dart';
import '../../domain/repositories/settings_repository.dart';
import '../db/backup_service.dart';
import 'cloud_backup_target.dart';

/// Puts the day's backup somewhere a lost phone cannot take it.
///
/// Deliberately dumb about *when*: closing the day asks it to send, and so
/// does opening the app if yesterday's never went. It is never a background
/// job competing with the POS while she is serving.
class CloudBackupService {
  const CloudBackupService({
    required BackupService backups,
    required SettingsRepository settings,
    required Clock clock,
    CloudBackupTarget? target,
  }) : _backups = backups,
       _settings = settings,
       _clock = clock,
       _target = target;

  final BackupService _backups;
  final SettingsRepository _settings;
  final Clock _clock;
  final CloudBackupTarget? _target;

  CloudBackupTarget? get target => _target;

  Future<bool> isConnected() async => await _target?.isConnected() ?? false;

  Future<String?> accountLabel() => _target?.accountLabel() ?? Future.value();

  /// When a backup last reached the cloud.
  Future<DateTime?> lastUploadAt() async {
    final String? raw = await _settings.readRaw(SettingKeys.cloudLastUploadAt);
    return raw == null || raw.isEmpty ? null : DateTime.tryParse(raw);
  }

  /// Why the last attempt failed, or null if the last one worked.
  Future<String?> lastError() async {
    final String? raw = await _settings.readRaw(SettingKeys.cloudLastError);
    return raw == null || raw.isEmpty ? null : raw;
  }

  /// Sends the newest backup, if there is one and it has not gone already.
  Future<CloudBackupOutcome> sendNewest() async {
    final BackupEntry? newest = await _backups.newest();
    if (newest == null) return CloudBackupOutcome.nothingToSend;
    if (newest.isOffDevice) return CloudBackupOutcome.alreadySent;
    return send(newest);
  }

  /// Sends one backup and records what happened.
  ///
  /// A failure is never thrown at the caller: closing the day must finish
  /// whether or not the shop has signal. It is recorded, shown on the Backup
  /// screen, and tried again next time.
  Future<CloudBackupOutcome> send(BackupEntry entry) async {
    final CloudBackupTarget? target = _target;
    if (target == null || !await target.isConnected()) {
      return CloudBackupOutcome.notConnected;
    }

    try {
      await target.upload(File(_backups.pathOf(entry)), name: entry.fileName);
    } on CloudBackupException catch (error) {
      await _settings.writeRaw(SettingKeys.cloudLastError, error.message);
      return error.isAuthProblem
          ? CloudBackupOutcome.signInExpired
          : CloudBackupOutcome.failed;
    }

    await _backups.markSent(entry);
    await _settings.writeRaw(
      SettingKeys.cloudLastUploadAt,
      _clock.now().toUtc().toIso8601String(),
    );
    await _settings.writeRaw(SettingKeys.cloudLastError, '');
    return CloudBackupOutcome.sent;
  }
}

/// What came of asking for a backup to be sent.
enum CloudBackupOutcome {
  sent('Saved to the cloud'),
  alreadySent('Already saved'),
  nothingToSend('There is no backup to send'),
  notConnected('No cloud account is connected'),
  signInExpired('The cloud sign-in has lapsed — connect it again'),
  failed('The backup could not be sent, and is still on the phone');

  const CloudBackupOutcome(this.message);

  final String message;

  bool get isSuccess =>
      this == CloudBackupOutcome.sent || this == CloudBackupOutcome.alreadySent;
}
