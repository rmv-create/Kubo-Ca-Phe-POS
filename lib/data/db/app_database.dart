import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import 'migrations/migration_runner.dart';

/// The single SQLite connection the whole app shares.
///
/// Everything the business owns lives in this one file: menu, recipes, costs,
/// inventory, customers, orders and closings. It is opened once at startup and
/// stays open — the POS must never wait on a connection while a customer is
/// standing there.
class AppDatabase {
  AppDatabase(this.db, {required this.path});

  final Database db;

  /// Absolute path on disk, or `:memory:` in tests.
  final String path;

  bool get isInMemory => path == inMemoryDatabasePath;

  /// Opens the database, applies pragmas, and migrates it forward.
  ///
  /// [onBeforeMigrate] runs after the connection is open but before any
  /// migration is applied — that is where the pre-migration backup is taken.
  static Future<AppDatabase> open({
    required DatabaseFactory factory,
    required String path,
    MigrationRunner runner = const MigrationRunner(),
    Future<void> Function(int currentVersion, int targetVersion)?
    onBeforeMigrate,
  }) async {
    final Database db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        // Migrations are run by our own runner, not by sqflite's version hook,
        // so that each one gets its own transaction and its own ledger row.
        onConfigure: _configure,
      ),
    );

    final AppDatabase database = AppDatabase(db, path: path);
    final int current = await runner.currentVersion(db);
    if (onBeforeMigrate != null && current < targetSchemaVersion) {
      await onBeforeMigrate(current, targetSchemaVersion);
    }
    await runner.run(db);
    return database;
  }

  static Future<void> _configure(Database db) async {
    // Referential integrity is off by default in SQLite and is per-connection.
    await db.execute('PRAGMA foreign_keys = ON');
    // WAL keeps reads (the menu, the customer search) from blocking the write
    // that completes an order.
    await db.execute('PRAGMA journal_mode = WAL');
    // A POS on a phone can lose power mid-sale. Durability beats throughput.
    await db.execute('PRAGMA synchronous = FULL');
    await db.execute('PRAGMA busy_timeout = 5000');
  }

  /// Runs [action] as one all-or-nothing unit.
  ///
  /// Order completion, refunds, voids, purchases and stock counts all go
  /// through here: either every row lands or none does. A failure is
  /// translated into a [StorageException] so callers never see raw SQLite
  /// errors.
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) async {
    try {
      return await db.transaction<T>(action);
    } on AppException {
      // Business failures are meaningful; let them through untouched. The
      // transaction has already rolled back.
      rethrow;
    } catch (error) {
      throw StorageException(
        'The change could not be saved and nothing was written.',
        cause: error,
      );
    }
  }

  /// Flushes the write-ahead log into the main database file so that the file
  /// can be copied as a complete, consistent backup.
  ///
  /// A closed connection needs no checkpoint — closing already flushed the WAL
  /// — and a restore deliberately closes the database before copying over it,
  /// so this must stay a no-op rather than an error in that case.
  Future<void> checkpoint() async {
    if (isInMemory || !db.isOpen) return;
    await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  }

  /// Verifies the file is not corrupt. Used before a restore is accepted.
  Future<bool> integrityCheck() async {
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'PRAGMA integrity_check',
    );
    return rows.length == 1 && rows.first.values.first == 'ok';
  }

  Future<void> close() => db.close();
}
