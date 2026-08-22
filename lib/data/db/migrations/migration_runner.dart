import 'package:sqflite_common/sqlite_api.dart';

import 'm001_initial_schema.dart';
import 'm002_customisation_prompting.dart';
import 'm003_payments_people_and_discounts.dart';
import 'm004_matcha_oat_latte.dart';
import 'migration.dart';

/// Every migration this app has ever shipped, in order.
///
/// Append only. Editing a released migration would leave existing installs on
/// a different schema than fresh ones.
const List<Migration> appMigrations = <Migration>[
  M001InitialSchema(),
  M002CustomisationPrompting(),
  M003PaymentsPeopleAndDiscounts(),
  M004MatchaOatLatte(),
];

/// The schema version a freshly built app expects.
int get targetSchemaVersion => appMigrations
    .map((Migration m) => m.version)
    .reduce((int a, int b) => a > b ? a : b);

/// Result of a migration run, so the caller can log it and the tests can assert
/// on it.
class MigrationOutcome {
  const MigrationOutcome({
    required this.fromVersion,
    required this.toVersion,
    required this.applied,
  });

  final int fromVersion;
  final int toVersion;
  final List<String> applied;

  bool get didMigrate => applied.isNotEmpty;
  bool get isFreshInstall => fromVersion == 0;
}

/// Applies pending migrations, one transaction per migration.
///
/// If a migration throws, its transaction rolls back and the database stays on
/// the last version that fully succeeded — never half-migrated.
class MigrationRunner {
  const MigrationRunner({this.migrations = appMigrations});

  final List<Migration> migrations;

  Future<MigrationOutcome> run(Database db) async {
    await _ensureLedger(db);
    final int current = await currentVersion(db);
    _assertContiguous();

    final List<Migration> pending =
        migrations.where((Migration m) => m.version > current).toList()
          ..sort((Migration a, Migration b) => a.version.compareTo(b.version));

    final List<String> applied = <String>[];
    for (final Migration migration in pending) {
      await db.transaction((Transaction txn) async {
        await migration.up(txn);
        await txn.insert('schema_migrations', <String, Object?>{
          'version': migration.version,
          'name': migration.name,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
      });
      // user_version is a cheap out-of-band marker for tooling; the ledger
      // table remains the authoritative record.
      await db.execute('PRAGMA user_version = ${migration.version}');
      applied.add('${migration.version}_${migration.name}');
    }

    return MigrationOutcome(
      fromVersion: current,
      toVersion: await currentVersion(db),
      applied: applied,
    );
  }

  /// Highest migration recorded as applied, or 0 for a brand-new database.
  Future<int> currentVersion(Database db) async {
    await _ensureLedger(db);
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT MAX(version) AS v FROM schema_migrations',
    );
    return (rows.first['v'] as int?) ?? 0;
  }

  Future<void> _ensureLedger(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version    INTEGER PRIMARY KEY,
        name       TEXT NOT NULL,
        applied_at TEXT NOT NULL
      )
    ''');
  }

  void _assertContiguous() {
    final List<int> versions =
        migrations.map((Migration m) => m.version).toList()..sort();
    for (int i = 0; i < versions.length; i++) {
      if (versions[i] != i + 1) {
        throw StateError(
          'Migration versions must be contiguous starting at 1; got $versions.',
        );
      }
    }
  }
}
