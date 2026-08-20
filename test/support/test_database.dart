import 'package:kubo_pos/core/time/clock.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/seed/menu_seeder.dart';
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
};

/// Opens a test database and writes the owner's menu into it, exactly as the
/// app does on first launch.
Future<AppDatabase> openSeededDatabase({FixedClock? clock}) async {
  final AppDatabase db = await openTestDatabase();
  await MenuSeeder(db, clock ?? testClock()).seedIfEmpty();
  return db;
}
