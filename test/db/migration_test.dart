import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/migrations/migration_runner.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;

  setUp(() async {
    database = await openTestDatabase();
  });

  tearDown(() async {
    await database.close();
  });

  group('migrations', () {
    test('a fresh database lands on the current schema version', () async {
      const MigrationRunner runner = MigrationRunner();
      expect(await runner.currentVersion(database.db), targetSchemaVersion);
    });

    test('records every migration it applied', () async {
      final List<Map<String, Object?>> rows = await database.db.query(
        'schema_migrations',
        orderBy: 'version',
      );
      expect(rows.length, appMigrations.length);
      expect(rows.first['name'], 'initial_schema');
      expect(rows.first['applied_at'], isNotNull);
    });

    test('running again applies nothing', () async {
      const MigrationRunner runner = MigrationRunner();
      final MigrationOutcome outcome = await runner.run(database.db);
      expect(outcome.didMigrate, isFalse);
      expect(outcome.applied, isEmpty);
      expect(outcome.fromVersion, targetSchemaVersion);
    });

    test('creates every table the schema promises', () async {
      final List<Map<String, Object?>> rows = await database.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%'",
      );
      final Set<String> actual = rows
          .map((Map<String, Object?> r) => r['name']! as String)
          .toSet();
      expect(actual, containsAll(expectedTables));
      expect(actual.contains('schema_migrations'), isTrue);
      // Nothing unexpected crept in.
      expect(
        actual.difference(expectedTables).difference(<String>{
          'schema_migrations',
          'sqlite_sequence',
        }),
        isEmpty,
      );
    });

    test('migration versions are contiguous from 1', () {
      final List<int> versions =
          appMigrations.map((dynamic m) => m.version as int).toList()..sort();
      for (int i = 0; i < versions.length; i++) {
        expect(versions[i], i + 1);
      }
    });

    test('the database reports itself intact', () async {
      expect(await database.integrityCheck(), isTrue);
    });
  });

  group('referential integrity', () {
    test('foreign keys are switched on', () async {
      final List<Map<String, Object?>> rows = await database.db.rawQuery(
        'PRAGMA foreign_keys',
      );
      expect(rows.first.values.first, 1);
    });

    test('a product cannot reference a category that does not exist', () async {
      expect(
        () => database.db.insert('products', <String, Object?>{
          'category_id': 999,
          'name': 'Orphan',
          'created_at': '2026-03-15T00:00:00Z',
          'updated_at': '2026-03-15T00:00:00Z',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('a category still used by a product cannot be deleted', () async {
      final int categoryId = await _insertCategory(database.db, 'Classics');
      await database.db.insert('products', <String, Object?>{
        'category_id': categoryId,
        'name': 'Sample product',
        'created_at': '2026-03-15T00:00:00Z',
        'updated_at': '2026-03-15T00:00:00Z',
      });
      expect(
        () => database.db.delete(
          'product_categories',
          where: 'id = ?',
          whereArgs: <Object?>[categoryId],
        ),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('deleting a product removes its size rows', () async {
      final int categoryId = await _insertCategory(database.db, 'Classics');
      final int sizeId = await _insertSize(database.db, 'small', 'Small', 12);
      final int productId = await database.db
          .insert('products', <String, Object?>{
            'category_id': categoryId,
            'name': 'Sample product',
            'created_at': '2026-03-15T00:00:00Z',
            'updated_at': '2026-03-15T00:00:00Z',
          });
      await database.db.insert('product_sizes', <String, Object?>{
        'product_id': productId,
        'size_id': sizeId,
        'price_centavos': 0,
        'created_at': '2026-03-15T00:00:00Z',
        'updated_at': '2026-03-15T00:00:00Z',
      });

      await database.db.delete(
        'products',
        where: 'id = ?',
        whereArgs: <Object?>[productId],
      );
      final List<Map<String, Object?>> remaining = await database.db.query(
        'product_sizes',
      );
      expect(remaining, isEmpty);
    });
  });

  group('constraints', () {
    test('a product cannot have the same size twice', () async {
      final int categoryId = await _insertCategory(database.db, 'Classics');
      final int sizeId = await _insertSize(database.db, 'grande', 'Grande', 16);
      final int productId = await database.db
          .insert('products', <String, Object?>{
            'category_id': categoryId,
            'name': 'Sample product',
            'created_at': '2026-03-15T00:00:00Z',
            'updated_at': '2026-03-15T00:00:00Z',
          });
      Future<int> addSize() =>
          database.db.insert('product_sizes', <String, Object?>{
            'product_id': productId,
            'size_id': sizeId,
            'price_centavos': 0,
            'created_at': '2026-03-15T00:00:00Z',
            'updated_at': '2026-03-15T00:00:00Z',
          });
      await addSize();
      expect(addSize, throwsA(isA<DatabaseException>()));
    });

    test('a price cannot be negative', () async {
      final int categoryId = await _insertCategory(database.db, 'Classics');
      final int sizeId = await _insertSize(database.db, 'small', 'Small', 12);
      final int productId = await database.db
          .insert('products', <String, Object?>{
            'category_id': categoryId,
            'name': 'Sample product',
            'created_at': '2026-03-15T00:00:00Z',
            'updated_at': '2026-03-15T00:00:00Z',
          });
      expect(
        () => database.db.insert('product_sizes', <String, Object?>{
          'product_id': productId,
          'size_id': sizeId,
          'price_centavos': -1,
          'created_at': '2026-03-15T00:00:00Z',
          'updated_at': '2026-03-15T00:00:00Z',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('an order status outside the allowed set is rejected', () async {
      expect(
        () => database.db.insert('orders', <String, Object?>{
          'order_no': 'X-0001',
          'created_at': '2026-03-15T00:00:00Z',
          'business_date': '2026-03-15',
          'status': 'pending',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('a payment method outside cash or gcash is rejected', () async {
      final int orderId = await database.db.insert('orders', <String, Object?>{
        'order_no': 'X-0002',
        'created_at': '2026-03-15T00:00:00Z',
        'business_date': '2026-03-15',
        'status': 'completed',
      });
      expect(
        () => database.db.insert('payments', <String, Object?>{
          'order_id': orderId,
          'method': 'card',
          'amount_centavos': 100,
          'status': 'confirmed',
          'created_at': '2026-03-15T00:00:00Z',
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('two orders cannot share an order number', () async {
      Future<int> add() => database.db.insert('orders', <String, Object?>{
        'order_no': 'K-0001',
        'created_at': '2026-03-15T00:00:00Z',
        'business_date': '2026-03-15',
        'status': 'completed',
      });
      await add();
      expect(add, throwsA(isA<DatabaseException>()));
    });

    test('a trading day can only be closed once', () async {
      Future<int> close() =>
          database.db.insert('daily_closings', <String, Object?>{
            'business_date': '2026-03-15',
            'closed_at': '2026-03-15T22:00:00Z',
          });
      await close();
      expect(close, throwsA(isA<DatabaseException>()));
    });
  });

  group('transactions', () {
    test('a failure part-way through writes nothing at all', () async {
      final int categoryId = await _insertCategory(database.db, 'Classics');

      await expectLater(
        database.transaction((Transaction txn) async {
          await txn.insert('products', <String, Object?>{
            'category_id': categoryId,
            'name': 'Half-written product',
            'created_at': '2026-03-15T00:00:00Z',
            'updated_at': '2026-03-15T00:00:00Z',
          });
          // Violates the category foreign key, so the whole unit must roll back.
          await txn.insert('products', <String, Object?>{
            'category_id': 999,
            'name': 'Doomed product',
            'created_at': '2026-03-15T00:00:00Z',
            'updated_at': '2026-03-15T00:00:00Z',
          });
        }),
        throwsA(isA<Exception>()),
      );

      final List<Map<String, Object?>> products = await database.db.query(
        'products',
      );
      expect(products, isEmpty);
    });
  });
}

Future<int> _insertCategory(DatabaseExecutor db, String name) =>
    db.insert('product_categories', <String, Object?>{
      'name': name,
      'created_at': '2026-03-15T00:00:00Z',
      'updated_at': '2026-03-15T00:00:00Z',
    });

Future<int> _insertSize(
  DatabaseExecutor db,
  String code,
  String name,
  double oz,
) => db.insert('sizes', <String, Object?>{
  'code': code,
  'name': name,
  'volume_oz': oz,
  'created_at': '2026-03-15T00:00:00Z',
  'updated_at': '2026-03-15T00:00:00Z',
});
