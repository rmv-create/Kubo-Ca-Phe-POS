import 'package:sqflite_common/sqlite_api.dart';

/// One forward-only schema change.
///
/// The database is never deleted to accommodate a schema change: the owner's
/// customers, orders, inventory, recipes and costs must survive every app
/// update, so every change ships as a numbered migration.
abstract class Migration {
  const Migration();

  /// Strictly increasing. Gaps are not allowed.
  int get version;

  /// Short human description, recorded in `schema_migrations`.
  String get name;

  /// Applied inside a transaction opened by the runner.
  Future<void> up(DatabaseExecutor db);
}
