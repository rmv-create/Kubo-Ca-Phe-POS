import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/core/time/clock.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/backup_service.dart';
import 'package:kubo_pos/data/db/migrations/migration_runner.dart';
import 'package:kubo_pos/domain/entities/backup_entry.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workDir;
  late AppDatabase database;
  late BackupService backups;
  late FixedClock clock;

  setUp(() async {
    sqfliteFfiInit();
    workDir = await Directory.systemTemp.createTemp('kubo_backup_test');
    clock = testClock();

    final String dbPath = p.join(workDir.path, 'kubo_pos.db');
    database = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: dbPath,
    );
    backups = BackupService(
      databasePath: dbPath,
      backupDirectory: Directory(p.join(workDir.path, 'backups')),
      clock: clock,
      checkpoint: () async => database.checkpoint(),
      schemaVersion: () async => targetSchemaVersion,
    );
  });

  tearDown(() async {
    await database.close();
    if (workDir.existsSync()) {
      await workDir.delete(recursive: true);
    }
  });

  test('creates a backup and records it in the manifest', () async {
    final BackupEntry entry = await backups.create();

    expect(entry.sizeBytes, greaterThan(0));
    expect(entry.schemaVersion, targetSchemaVersion);
    expect(entry.sha256, isNotEmpty);
    expect(
      File(p.join(workDir.path, 'backups', entry.fileName)).existsSync(),
      isTrue,
    );

    final List<BackupEntry> listed = await backups.listBackups();
    expect(listed.length, 1);
    expect(listed.first.fileName, entry.fileName);
  });

  test('the file name says why the backup was taken', () async {
    final BackupEntry entry = await backups.create(
      reason: BackupReason.preMigration,
    );
    expect(entry.fileName, contains('pre_migration'));
    expect(entry.reason, BackupReason.preMigration);
  });

  test('verifies an intact backup and rejects a corrupted one', () async {
    final BackupEntry entry = await backups.create();
    expect(await backups.verify(entry), isTrue);

    final File file = File(p.join(workDir.path, 'backups', entry.fileName));
    await file.writeAsBytes(<int>[0, 1, 2, 3]);
    expect(await backups.verify(entry), isFalse);
  });

  test('a corrupted backup is refused rather than restored', () async {
    final BackupEntry entry = await backups.create();
    await File(
      p.join(workDir.path, 'backups', entry.fileName),
    ).writeAsBytes(<int>[9, 9, 9]);
    await expectLater(backups.restore(entry), throwsA(isA<BackupException>()));
  });

  test('pruning keeps the newest and never empties the folder', () async {
    for (int i = 0; i < 5; i++) {
      clock.advance(const Duration(minutes: 1));
      await backups.create();
    }
    expect((await backups.listBackups()).length, 5);

    final int removed = await backups.prune(keep: 2);
    expect(removed, 3);

    final List<BackupEntry> remaining = await backups.listBackups();
    expect(remaining.length, 2);
    // Newest first, so the two survivors are the two most recent.
    expect(remaining.first.createdAt.isAfter(remaining.last.createdAt), isTrue);
  });

  test('pruning never deletes a pre-migration backup', () async {
    await backups.create(reason: BackupReason.preMigration);
    for (int i = 0; i < 3; i++) {
      clock.advance(const Duration(minutes: 1));
      await backups.create();
    }

    await backups.prune(keep: 1);
    final List<BackupEntry> remaining = await backups.listBackups();
    expect(
      remaining.any((BackupEntry e) => e.reason == BackupReason.preMigration),
      isTrue,
      reason: 'the copy taken before an upgrade is the one that matters most',
    );
  });

  test('pruning a single backup leaves it alone', () async {
    await backups.create();
    expect(await backups.prune(keep: 0), 0);
    expect((await backups.listBackups()).length, 1);
  });

  test('restoring backs the current database up first', () async {
    final BackupEntry entry = await backups.create();
    clock.advance(const Duration(minutes: 5));

    await database.close();
    await backups.restore(entry);

    final List<BackupEntry> listed = await backups.listBackups();
    expect(
      listed.any((BackupEntry e) => e.reason == BackupReason.preRestore),
      isTrue,
    );
  });

  test('restoring brings back data that was deleted afterwards', () async {
    await database.db.insert('product_categories', <String, Object?>{
      'name': 'Classics',
      'created_at': '2026-03-15T00:00:00Z',
      'updated_at': '2026-03-15T00:00:00Z',
    });
    final BackupEntry entry = await backups.create();

    await database.db.delete('product_categories');
    expect(await database.db.query('product_categories'), isEmpty);

    final String dbPath = database.path;
    await database.close();
    await backups.restore(entry);

    database = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: dbPath,
    );
    final List<Map<String, Object?>> rows = await database.db.query(
      'product_categories',
    );
    expect(rows.length, 1);
    expect(rows.first['name'], 'Classics');
  });

  test('an empty folder lists no backups rather than failing', () async {
    expect(await backups.listBackups(), isEmpty);
  });
}
