import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../../core/errors/app_exception.dart';
import '../../core/time/clock.dart';
import 'migrations/migration_runner.dart';

/// The whole shop as one file of SQL text.
///
/// The file-based backup copies the database on disk, which is the right
/// thing on a phone and impossible in a browser, where there is no disk to
/// copy. This writes the contents instead: every row of every table as
/// statements that put them back.
///
/// It is also the one backup format that can be read by a person, and that
/// moves between the web version and the phone version, because it carries
/// data rather than a file layout.
class DatabaseArchive {
  const DatabaseArchive(this._db, this._clock);

  final DatabaseExecutor _db;
  final Clock _clock;

  static const String _magic = 'Kubo Cà Phê backup';
  static const int formatVersion = 1;

  /// Tables SQLite keeps for itself, which are rebuilt rather than restored.
  static const Set<String> _internal = <String>{'android_metadata'};

  /// Every row in the database, as SQL.
  Future<String> export() async {
    final int schema = await _schemaVersion();
    final StringBuffer out = StringBuffer()
      ..writeln('-- $_magic')
      ..writeln('-- format: $formatVersion')
      ..writeln('-- schema: $schema')
      ..writeln('-- taken: ${_clock.now().toUtc().toIso8601String()}')
      ..writeln(
        '--\n'
        '-- Every row of the shop, in the order they go back.\n'
        '-- Restore it from Manage → Backup; or keep it, open it, read it.',
      )
      ..writeln();

    for (final String table in await _tables()) {
      final List<Map<String, Object?>> rows = await _db.query(table);
      if (rows.isEmpty) continue;
      out.writeln('-- $table (${rows.length})');
      for (final Map<String, Object?> row in rows) {
        out.writeln(_insert(table, row));
      }
      out.writeln();
    }
    return out.toString();
  }

  /// Puts an exported file back, replacing everything that is there.
  ///
  /// All or nothing: one transaction, foreign keys relaxed while the rows go
  /// in (they arrive in table order, not dependency order) and checked again
  /// at the end. A file from a newer version of the app is refused rather
  /// than half-applied.
  Future<void> restore(String sql) async {
    if (!sql.contains(_magic)) {
      throw const BackupException('That file is not a Kubo backup.');
    }
    final int fileSchema = _headerInt(sql, 'schema') ?? 0;
    final int here = await _schemaVersion();
    if (fileSchema > here) {
      throw BackupException(
        'That backup came from a newer version of Kubo (database v$fileSchema '
        'against v$here here). Update the app first.',
      );
    }

    final List<String> statements = _statements(sql);
    if (statements.isEmpty) {
      throw const BackupException('That backup has nothing in it.');
    }

    // Read before the transaction opens: a query against the database while
    // one of its own transactions is in flight waits for a lock that will
    // never be given up.
    final List<String> tables = await _tables();

    final Database db = _db as Database;
    await db.execute('PRAGMA foreign_keys = OFF');
    try {
      await db.transaction((Transaction txn) async {
        for (final String table in tables.reversed) {
          await txn.delete(table);
        }
        for (final String statement in statements) {
          await txn.execute(statement);
        }
      });
    } finally {
      await db.execute('PRAGMA foreign_keys = ON');
    }

    final List<Map<String, Object?>> broken = await db.rawQuery(
      'PRAGMA foreign_key_check',
    );
    if (broken.isNotEmpty) {
      throw const BackupException(
        'That backup restored, but the records do not hang together. '
        'Restore a different one.',
      );
    }
  }

  /// A one-line summary of a file, for showing before restoring it.
  static ArchiveHeader? describe(String sql) {
    if (!sql.contains(_magic)) return null;
    final String? taken = _headerValue(sql, 'taken');
    return ArchiveHeader(
      schemaVersion: _headerInt(sql, 'schema') ?? 0,
      takenAt: taken == null ? null : DateTime.tryParse(taken),
      rowCount: _statements(sql).length,
    );
  }

  Future<int> _schemaVersion() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      'PRAGMA user_version',
    );
    final int stored = (rows.first.values.first as int?) ?? 0;
    return stored == 0 ? targetSchemaVersion : stored;
  }

  /// Every table that holds the shop's own data, in creation order.
  Future<List<String>> _tables() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY rootpage",
    );
    return <String>[
      for (final Map<String, Object?> row in rows)
        if (!_internal.contains(row['name'])) row['name']! as String,
    ];
  }

  static String _insert(String table, Map<String, Object?> row) {
    final List<String> columns = row.keys.toList();
    return 'INSERT INTO "$table" '
        '(${columns.map((String c) => '"$c"').join(',')}) VALUES '
        '(${columns.map((String c) => _literal(row[c])).join(',')});';
  }

  /// SQL literals, with text quoted the way SQLite expects.
  static String _literal(Object? value) => switch (value) {
    null => 'NULL',
    final int v => '$v',
    final double v => '$v',
    // Nothing in this schema stores binary, but a stray blob must not
    // silently become the word "Instance of ...".
    final List<int> v =>
      "X'${v.map((int b) => b.toRadixString(16).padLeft(2, '0')).join()}'",
    _ => "'${value.toString().replaceAll("'", "''")}'",
  };

  /// The INSERT statements, skipping the comments and the blank lines.
  static List<String> _statements(String sql) => <String>[
    for (final String line in const LineSplitter().convert(sql))
      if (line.startsWith('INSERT INTO ')) line.substring(0, line.length - 1),
  ];

  static String? _headerValue(String sql, String key) {
    for (final String line in const LineSplitter().convert(sql)) {
      if (line.startsWith('-- $key: ')) {
        return line.substring('-- $key: '.length).trim();
      }
      if (line.startsWith('INSERT')) break;
    }
    return null;
  }

  static int? _headerInt(String sql, String key) =>
      int.tryParse(_headerValue(sql, key) ?? '');
}

/// What an exported file says about itself.
class ArchiveHeader {
  const ArchiveHeader({
    required this.schemaVersion,
    required this.rowCount,
    this.takenAt,
  });

  final int schemaVersion;
  final int rowCount;
  final DateTime? takenAt;
}
