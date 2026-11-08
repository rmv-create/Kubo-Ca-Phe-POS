/// Which tables travel between devices, and how a clash is settled.
///
/// Two tills that have both been serving have to agree afterwards. What
/// makes that safe is not cleverness but the shape of the data: nearly
/// everything the POS writes is a *record of something that happened*, and
/// two records of two different things never conflict — they merge.
enum SyncKind {
  /// Facts. An order was rung up; stock came out; money was taken. Written
  /// once and never changed, so merging is union: every device ends up
  /// holding every event, and nothing is lost or overwritten.
  ///
  /// Stock on hand is deliberately **not** an event. It is a running total
  /// of the movement ledger, so it is recomputed from the merged events
  /// rather than synced — which is what stops two tills that both sold the
  /// last cup from quietly agreeing on the wrong number.
  event,

  /// Things the owner maintains: the menu, the recipes, the prices, the
  /// staff. Edited rarely, and almost always on one device. Last edit wins,
  /// row by row, by `updated_at`.
  reference,

  /// Rows that are a summary of events elsewhere. A customer's visit count
  /// and total spend are rebuilt from the orders rather than merged.
  derived,
}

/// One table's place in the scheme.
class SyncedTable {
  const SyncedTable(this.name, this.kind, {this.parent});

  final String name;
  final SyncKind kind;

  /// The table whose row this one belongs to, for rows that only make sense
  /// as part of a whole — an order's lines travel with the order.
  final String? parent;

  bool get isEvent => kind == SyncKind.event;
}

/// Every table that crosses between devices.
///
/// Three are missing on purpose: `inventory`, the running stock total,
/// recomputed from the ledger; `schema_migrations`, which each device keeps
/// for itself; and the sync queue itself.
const List<SyncedTable> syncedTables = <SyncedTable>[
  // ── what happened ──
  SyncedTable('orders', SyncKind.event),
  SyncedTable('order_items', SyncKind.event, parent: 'orders'),
  SyncedTable(
    'order_item_customizations',
    SyncKind.event,
    parent: 'order_items',
  ),
  SyncedTable('order_discounts', SyncKind.event, parent: 'orders'),
  SyncedTable('payments', SyncKind.event, parent: 'orders'),
  SyncedTable('refunds', SyncKind.event, parent: 'orders'),
  SyncedTable('refund_items', SyncKind.event, parent: 'refunds'),
  SyncedTable('order_voids', SyncKind.event, parent: 'orders'),
  SyncedTable('inventory_movements', SyncKind.event),
  SyncedTable('waste', SyncKind.event),
  SyncedTable('stock_counts', SyncKind.event),
  SyncedTable('stock_count_items', SyncKind.event, parent: 'stock_counts'),
  SyncedTable('purchases', SyncKind.event),
  SyncedTable('purchase_items', SyncKind.event, parent: 'purchases'),
  SyncedTable('daily_closings', SyncKind.event),
  SyncedTable('audit_log', SyncKind.event),

  // ── what the shop is ──
  SyncedTable('product_categories', SyncKind.reference),
  SyncedTable('sizes', SyncKind.reference),
  SyncedTable('products', SyncKind.reference),
  SyncedTable('product_sizes', SyncKind.reference, parent: 'products'),
  SyncedTable('customization_groups', SyncKind.reference),
  SyncedTable(
    'customization_options',
    SyncKind.reference,
    parent: 'customization_groups',
  ),
  SyncedTable('option_ingredient_effects', SyncKind.reference),
  SyncedTable(
    'product_customization_groups',
    SyncKind.reference,
    parent: 'products',
  ),
  SyncedTable(
    'product_default_options',
    SyncKind.reference,
    parent: 'products',
  ),
  SyncedTable('product_option_prices', SyncKind.reference, parent: 'products'),
  SyncedTable('suppliers', SyncKind.reference),
  SyncedTable('ingredients', SyncKind.reference),
  SyncedTable('supplier_ingredients', SyncKind.reference, parent: 'suppliers'),
  SyncedTable('ingredient_cost_history', SyncKind.reference),
  SyncedTable('recipes', SyncKind.reference),
  SyncedTable('recipe_versions', SyncKind.reference, parent: 'recipes'),
  SyncedTable('recipe_items', SyncKind.reference, parent: 'recipe_versions'),
  SyncedTable('payment_methods', SyncKind.reference),
  SyncedTable('discounts', SyncKind.reference),
  SyncedTable('app_users', SyncKind.reference),
  SyncedTable('app_settings', SyncKind.reference),

  // ── who buys what ──
  SyncedTable('customers', SyncKind.reference),
  SyncedTable('customer_order_patterns', SyncKind.derived, parent: 'customers'),
];

/// The names, for the migration and the sync engine.
List<String> get syncedTableNames => <String>[
  for (final SyncedTable t in syncedTables) t.name,
];
