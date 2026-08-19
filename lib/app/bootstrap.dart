import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import '../core/time/clock.dart';
import '../data/db/app_database.dart';
import '../data/db/backup_service.dart';
import '../data/db/migrations/migration_runner.dart';
import '../data/repositories/settings_repository_impl.dart';
import '../domain/entities/backup_entry.dart';
import '../domain/entities/business_settings.dart';
import 'providers.dart';

/// Everything the app needs before its first frame.
class AppBootstrap {
  const AppBootstrap({
    required this.database,
    required this.backupService,
    required this.settings,
    required this.clock,
  });

  final AppDatabase database;
  final BackupService backupService;
  final BusinessSettings settings;
  final Clock clock;

  /// Riverpod overrides that hand the running app its real infrastructure.
  /// Tests supply their own, pointing at an in-memory database.
  List<Override> get overrides => <Override>[
    databaseProvider.overrideWithValue(database),
    backupServiceProvider.overrideWithValue(backupService),
    clockProvider.overrideWithValue(clock),
    initialSettingsProvider.overrideWithValue(settings),
  ];
}

/// Opens the database, backs it up if it is about to be migrated, applies
/// migrations, loads settings, and takes the once-a-day automatic backup.
///
/// Runs before `runApp`, so a failure here is visible rather than silently
/// leaving the owner with a POS that cannot save.
Future<AppBootstrap> bootstrapApp({Clock clock = const SystemClock()}) async {
  final Directory supportDir = await getApplicationSupportDirectory();
  final Directory documentsDir = await getApplicationDocumentsDirectory();

  final String databasePath = p.join(supportDir.path, 'kubo_pos.db');
  // Backups live in Documents so the owner can pull them off the device with
  // the Files app — the iOS target enables file sharing for exactly this.
  final Directory backupDir = Directory(p.join(documentsDir.path, 'backups'));

  late final AppDatabase database;
  late final BackupService backups;

  backups = BackupService(
    databasePath: databasePath,
    backupDirectory: backupDir,
    clock: clock,
    checkpoint: () async => database.checkpoint(),
    schemaVersion: () async => targetSchemaVersion,
  );

  database = await AppDatabase.open(
    factory: sqflite.databaseFactory,
    path: databasePath,
    onBeforeMigrate: (int from, int to) async {
      // A fresh install has nothing worth saving; an upgrade always does.
      if (from == 0) return;
      await backups.create(reason: BackupReason.preMigration);
    },
  );

  final SettingsRepositoryImpl settingsRepository = SettingsRepositoryImpl(
    database,
    clock,
  );
  final BusinessSettings settings = await settingsRepository.load();

  await _runDailyBackup(
    backups: backups,
    repository: settingsRepository,
    settings: settings,
    clock: clock,
  );

  return AppBootstrap(
    database: database,
    backupService: backups,
    settings: settings,
    clock: clock,
  );
}

/// Takes at most one automatic backup per business day, then prunes.
Future<void> _runDailyBackup({
  required BackupService backups,
  required SettingsRepositoryImpl repository,
  required BusinessSettings settings,
  required Clock clock,
}) async {
  if (!settings.autoBackupDaily) return;

  final BusinessDay day = BusinessDay(
    cutoffHour: settings.businessDayCutoffHour,
  );
  final String today = day.dateOf(clock.now());
  final String? last = await repository.readRaw(SettingKeys.lastAutoBackupDate);
  if (last == today) return;

  try {
    await backups.create(reason: BackupReason.automaticDaily);
    await backups.prune(keep: settings.backupRetentionCount);
    await repository.writeRaw(SettingKeys.lastAutoBackupDate, today);
  } catch (_) {
    // A failed backup must never stop the owner from taking orders. The
    // Backup screen surfaces the real state; the POS carries on.
  }
}
