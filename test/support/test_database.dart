import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/time/clock.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/migrations/migration.dart';
import 'package:kubo_pos/data/db/migrations/migration_runner.dart';
import 'package:kubo_pos/data/db/seed/menu_seeder.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens a migrated, empty database in memory.
///
/// The whole data and business layer is testable without a simulator or a
/// device, which is what makes it practical to keep the suite green on every
/// commit.
Future<AppDatabase> openTestDatabase() async {
  sqfliteFfiInit();
  return AppDatabase.open(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
}

/// Opens a database migrated only as far as [version].
///
/// Lets a test stand where a real installed app stands before an update, so
/// the upgrade path is exercised rather than assumed.
Future<AppDatabase> openTestDatabaseAt(int version) async {
  sqfliteFfiInit();
  // A real file, not `:memory:`: the ffi factory hands back the *same*
  // connection for every in-memory open, so two of them would be one database.
  final Directory dir = await Directory.systemTemp.createTemp('kubo_upgrade');
  addTearDown(() => dir.delete(recursive: true));
  return AppDatabase.open(
    factory: databaseFactoryFfi,
    path: p.join(dir.path, 'kubo.db'),
    runner: MigrationRunner(
      migrations: appMigrations
          .where((Migration m) => m.version <= version)
          .toList(),
    ),
  );
}

/// A clock frozen at a readable moment, so date-dependent assertions are
/// stable.
FixedClock testClock([DateTime? at]) =>
    FixedClock(at ?? DateTime(2026, 3, 15, 10, 30));

/// Names of every table the V1 schema creates, excluding the migration ledger.
const Set<String> expectedTables = <String>{
  'app_settings',
  'audit_log',
  'product_categories',
  'sizes',
  'products',
  'product_sizes',
  'customization_groups',
  'customization_options',
  'option_ingredient_effects',
  'product_customization_groups',
  'product_default_options',
  'suppliers',
  'ingredients',
  'supplier_ingredients',
  'ingredient_cost_history',
  'recipes',
  'recipe_versions',
  'recipe_items',
  'inventory',
  'inventory_movements',
  'stock_counts',
  'stock_count_items',
  'waste',
  'purchases',
  'purchase_items',
  'customers',
  'customer_order_patterns',
  'orders',
  'order_items',
  'order_item_customizations',
  'payments',
  'refunds',
  'refund_items',
  'order_voids',
  'daily_closings',
  'discounts',
  'payment_methods',
  'app_users',
  'order_discounts',
  'product_option_prices',
};

/// Opens a test database and writes the owner's menu into it, exactly as the
/// app does on first launch.
Future<AppDatabase> openSeededDatabase({FixedClock? clock}) async {
  final AppDatabase db = await openTestDatabase();
  await MenuSeeder(db, clock ?? testClock()).seedIfEmpty();
  return db;
}
