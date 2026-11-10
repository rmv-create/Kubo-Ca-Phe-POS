import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import '../core/time/clock.dart';
import '../data/cloud/cloud_backup_service.dart';
import '../data/cloud/google_drive_target.dart';
import '../data/db/app_database.dart';
import '../data/db/archive_file.dart';
import '../data/db/backup_service.dart';
import '../data/db/migrations/migration_runner.dart';
import '../data/db/seed/menu_seeder.dart';
import '../data/db/seed/pantry_seeder.dart';
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

  await _seedIfThisPhoneHasAShop(database, clock);

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

/// Writes the menu, but only onto a phone that is already running a shop.
///
/// This used to happen on every first launch, which is how a stranger with
/// the link ended up with a complete working copy of Kubo, and how a barista
/// opening the same link got a blank shop of her own rather than her
/// employer's. A phone now gets the menu when its owner opens a shop on it,
/// and at no other time: see [ShopAccessService].
///
/// Phones that were already trading before any of this existed keep working
/// untouched. That is what the check is for — the seeders themselves refuse
/// to overwrite, so this only decides whether a *blank* phone is filled.
Future<void> _seedIfThisPhoneHasAShop(AppDatabase db, Clock clock) async {
  final List<Map<String, Object?>> products = await db.db.rawQuery(
    'SELECT 1 FROM products LIMIT 1',
  );
  final List<Map<String, Object?>> users = await db.db.rawQuery(
    'SELECT 1 FROM app_users LIMIT 1',
  );
  if (products.isEmpty && users.isEmpty) return;

  await MenuSeeder(db, clock).seedIfEmpty();
  await PantrySeeder(db, clock).seedIfEmpty();

  // A phone can hold a menu that is real but incomplete: it signed in while
  // the owner's till had pushed only part of the shop, and a half-arrived
  // menu looks exactly like a finished one to a seeder that only asks
  // whether the table is empty. Only the owner's phone repairs itself this
  // way — a barista's till takes the shop from the owner, and inventing
  // drinks of its own would give the two phones different ones.
  if (await _isOwner(db)) {
    await MenuSeeder(db, clock).repairMissing();
  }
}

/// Whether this phone is the owner's, rather than a barista's till.
Future<bool> _isOwner(AppDatabase db) async {
  final List<Map<String, Object?>> rows = await db.db.query(
    'app_settings',
    columns: <String>['value'],
    where: 'key = ?',
    whereArgs: <Object?>[SettingKeys.syncRole],
    limit: 1,
  );
  // A phone that was trading before any of the sync existed has no role at
  // all, and it is hers: there was only ever one.
  if (rows.isEmpty) return true;
  return (rows.first['value'] as String?) != 'barista';
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

  // Yesterday's closing backup may never have gone up — she closed with no
  // signal, or in a hurry. Opening the app is the next chance to try, and it
  // costs nothing when there is nothing to send.
  if (!kIsWeb && GoogleDriveTarget.isAvailable) {
    unawaited(
      CloudBackupService(
        backups: backups,
        settings: repository,
        clock: clock,
        target: GoogleDriveTarget(),
      ).sendNewest().catchError((_) => CloudBackupOutcome.failed),
    );
  }
}

/// Browser bootstrap: SQLite compiled to WebAssembly, persisted in IndexedDB.
///
/// Everything above the database is identical — same schema, same migrations,
/// same seed, same engines. Only the file-backed backup service is stood down,
/// because a browser has no folder to write into.
Future<AppBootstrap> _bootstrapWeb(Clock clock) async {
  // Browser storage is "best effort" by default: Safari and Chrome may clear
  // it when the device is short of space or the site is left alone. Asking
  // for persistence promotes it to storage the browser keeps until the owner
  // clears it herself. It is a request, not a guarantee — which is why the
  // Backup screen still presses her for a file she holds.
  await requestPersistentStorage();

  final DatabaseFactory factory = databaseFactoryFfiWeb;
  final AppDatabase database = await AppDatabase.open(
    factory: factory,
    path: 'kubo_pos.db',
  );

  await _seedIfThisPhoneHasAShop(database, clock);

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
