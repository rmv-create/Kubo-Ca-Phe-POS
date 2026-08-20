import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import '../core/time/clock.dart';
import '../data/db/app_database.dart';
import '../data/db/backup_service.dart';
import '../data/db/migrations/migration_runner.dart';
import '../data/db/seed/menu_seeder.dart';
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
    required this.exportDirectory,
  });

  final AppDatabase database;
  final BackupService backupService;
  final BusinessSettings settings;
  final Clock clock;
  final Directory exportDirectory;

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
  // On the web there is no real filesystem: the database lives in browser
  // storage and there is nowhere to copy a backup file to. That path exists
  // for demonstrating the app in a browser; iOS and iPadOS are the real
  // targets and take the branch below.
  if (kIsWeb) return _bootstrapWeb(clock);

  final Directory supportDir = await getApplicationSupportDirectory();
  final Directory documentsDir = await getApplicationDocumentsDirectory();

  final String databasePath = p.join(supportDir.path, 'kubo_pos.db');
  // Backups live in Documents so the owner can pull them off the device with
  // the Files app — the iOS target enables file sharing for exactly this.
  final Directory backupDir = Directory(p.join(documentsDir.path, 'backups'));
  // Exports sit beside the backups, in the folder the Files app can reach.
  final Directory exportDir = Directory(p.join(documentsDir.path, 'exports'));

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

  // First launch only: writes the owner's menu from her setup worksheet.
  // Refuses to run if any product already exists, so her later edits are never
  // overwritten by a seed on a subsequent launch.
  await MenuSeeder(database, clock).seedIfEmpty();

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
    exportDirectory: exportDir,
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

/// Browser bootstrap: SQLite compiled to WebAssembly, persisted in IndexedDB.
///
/// Everything above the database is identical — same schema, same migrations,
/// same seed, same engines. Only the file-backed backup service is stood down,
/// because a browser has no folder to write into.
Future<AppBootstrap> _bootstrapWeb(Clock clock) async {
  final DatabaseFactory factory = databaseFactoryFfiWeb;
  final AppDatabase database = await AppDatabase.open(
    factory: factory,
    path: 'kubo_pos.db',
  );

  await MenuSeeder(database, clock).seedIfEmpty();

  final SettingsRepositoryImpl settingsRepository = SettingsRepositoryImpl(
    database,
    clock,
  );
  final BusinessSettings settings = await settingsRepository.load();

  final Directory exportDir = Directory('exports');
  return AppBootstrap(
    database: database,
    backupService: BackupService(
      databasePath: 'kubo_pos.db',
      backupDirectory: Directory('backups'),
      clock: clock,
      checkpoint: () async => database.checkpoint(),
      schemaVersion: () async => targetSchemaVersion,
    ),
    settings: settings,
    clock: clock,
    exportDirectory: exportDir,
  );
}
