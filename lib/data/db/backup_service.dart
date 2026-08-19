// Backup work runs on the UI isolate while the owner is looking at the
// Backup screen. Async `dart:io` is deliberate here: a synchronous copy of
// a multi-megabyte database would freeze the frame. The lint prefers the
// sync variants for throughput; responsiveness matters more.
// ignore_for_file: avoid_slow_async_io

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../core/time/clock.dart';
import '../../domain/entities/backup_entry.dart';

/// Keeps timestamped copies of the SQLite file.
///
/// The whole business lives in one file on one phone, so backups are not a
/// nicety. Rules this service enforces:
///  * the WAL is checkpointed before a copy, so the copy is complete;
///  * a backup is taken before every migration and before every restore;
///  * pruning never removes the last remaining backup, nor any pre-migration
///    or pre-restore backup.
class BackupService {
  BackupService({
    required this.databasePath,
    required this.backupDirectory,
    required Clock clock,
    required Future<void> Function() checkpoint,
    required Future<int> Function() schemaVersion,
  }) : _clock = clock,
       _checkpoint = checkpoint,
       _schemaVersion = schemaVersion;

  final String databasePath;
  final Directory backupDirectory;
  final Clock _clock;
  final Future<void> Function() _checkpoint;
  final Future<int> Function() _schemaVersion;

  static const String manifestFileName = 'manifest.json';

  File get _manifestFile =>
      File(p.join(backupDirectory.path, manifestFileName));

  Future<BackupEntry> create({
    BackupReason reason = BackupReason.manual,
  }) async {
    final File source = File(databasePath);
    if (!await source.exists()) {
      throw const BackupException('There is no database file to back up yet.');
    }

    await backupDirectory.create(recursive: true);
    await _checkpoint();

    final DateTime now = _clock.now();
    final String stamp = _stamp(now);
    final String fileName = 'kubo_${stamp}_${reason.code}.db';
    final File target = File(p.join(backupDirectory.path, fileName));

    try {
      await source.copy(target.path);
    } catch (error) {
      throw BackupException('The backup could not be written.', cause: error);
    }

    final List<int> bytes = await target.readAsBytes();
    final BackupEntry entry = BackupEntry(
      fileName: fileName,
      createdAt: now,
      reason: reason,
      sizeBytes: bytes.length,
      schemaVersion: await _schemaVersion(),
      sha256: sha256.convert(bytes).toString(),
    );

    final List<BackupEntry> manifest = await listBackups();
    await _writeManifest(<BackupEntry>[entry, ...manifest]);
    return entry;
  }

  /// Newest first. Entries whose file has disappeared are dropped.
  Future<List<BackupEntry>> listBackups() async {
    if (!await _manifestFile.exists()) return <BackupEntry>[];
    try {
      final Object? decoded = jsonDecode(await _manifestFile.readAsString());
      if (decoded is! List) return <BackupEntry>[];
      final List<BackupEntry> entries =
          decoded
              .whereType<Map<String, Object?>>()
              .map(BackupEntry.fromJson)
              .where(
                (BackupEntry e) =>
                    File(p.join(backupDirectory.path, e.fileName)).existsSync(),
              )
              .toList()
            ..sort(
              (BackupEntry a, BackupEntry b) =>
                  b.createdAt.compareTo(a.createdAt),
            );
      return entries;
    } catch (_) {
      // A damaged manifest must not stop the app from starting or from taking
      // a fresh backup.
      return <BackupEntry>[];
    }
  }

  /// Deletes the oldest unprotected backups beyond [keep].
  ///
  /// Never deletes the only backup, and never deletes a pre-migration or
  /// pre-restore copy.
  Future<int> prune({required int keep}) async {
    final List<BackupEntry> all = await listBackups();
    if (all.length <= 1) return 0;

    final List<BackupEntry> protectedEntries = all
        .where((BackupEntry e) => e.reason.isProtected)
        .toList();
    final List<BackupEntry> prunable = all
        .where((BackupEntry e) => !e.reason.isProtected)
        .toList();

    final int keepCount = keep < 1 ? 1 : keep;
    if (prunable.length <= keepCount) return 0;

    final List<BackupEntry> kept = prunable.take(keepCount).toList();
    final List<BackupEntry> doomed = prunable.skip(keepCount).toList();

    for (final BackupEntry entry in doomed) {
      final File file = File(p.join(backupDirectory.path, entry.fileName));
      if (await file.exists()) {
        await file.delete();
      }
    }

    await _writeManifest(<BackupEntry>[...kept, ...protectedEntries]);
    return doomed.length;
  }

  /// Verifies a backup's checksum still matches what was recorded.
  Future<bool> verify(BackupEntry entry) async {
    final File file = File(p.join(backupDirectory.path, entry.fileName));
    if (!await file.exists()) return false;
    final List<int> bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString() == entry.sha256;
  }

  /// Copies a backup over the live database file.
  ///
  /// The caller must close the database first and reopen it afterwards, so
  /// that migrations re-run against the restored file. The current database is
  /// itself backed up before being replaced.
  Future<void> restore(BackupEntry entry) async {
    final File file = File(p.join(backupDirectory.path, entry.fileName));
    if (!await file.exists()) {
      throw BackupException('Backup ${entry.fileName} is missing.');
    }
    if (!await verify(entry)) {
      throw BackupException(
        'Backup ${entry.fileName} does not match its checksum and was not restored.',
      );
    }

    await create(reason: BackupReason.preRestore);

    final File live = File(databasePath);
    for (final String suffix in <String>['-wal', '-shm']) {
      final File sidecar = File('$databasePath$suffix');
      if (await sidecar.exists()) await sidecar.delete();
    }
    await file.copy(live.path);
  }

  Future<void> _writeManifest(List<BackupEntry> entries) async {
    await backupDirectory.create(recursive: true);
    final List<BackupEntry> sorted = List<BackupEntry>.of(entries)
      ..sort(
        (BackupEntry a, BackupEntry b) => b.createdAt.compareTo(a.createdAt),
      );
    await _manifestFile.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(sorted.map((BackupEntry e) => e.toJson()).toList()),
      flush: true,
    );
  }

  static String _stamp(DateTime moment) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${moment.year}${two(moment.month)}${two(moment.day)}'
        '_${two(moment.hour)}${two(moment.minute)}${two(moment.second)}';
  }
}
