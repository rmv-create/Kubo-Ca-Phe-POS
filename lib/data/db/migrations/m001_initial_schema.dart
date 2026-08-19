import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// The complete V1 schema.
///
/// Conventions used throughout:
///  * money   → `INTEGER` centavos (never REAL)
///  * amounts → `INTEGER` milli-base-units (thousandths of g / ml / pcs)
///  * costs   → `INTEGER` centavos per 1000 base units
///  * times   → `TEXT` ISO-8601 **UTC**, alongside a local `business_date`
///              (`YYYY-MM-DD`) on every transactional table for fast reporting
///  * booleans→ `INTEGER` 0/1
class M001InitialSchema extends Migration {
  const M001InitialSchema();

  @override
  int get version => 1;

  @override
  String get name => 'initial_schema';

  @override
  Future<void> up(DatabaseExecutor db) async {
    for (final String statement in _statements) {
      await db.execute(statement);
    }
  }
}

const List<String> _statements = <String>[
  // ───────────────────────── settings & audit ─────────────────────────
  '''
  CREATE TABLE app_settings (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  )
  ''',
  '''
  CREATE TABLE audit_log (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    at            TEXT NOT NULL,
    business_date TEXT NOT NULL,
    action        TEXT NOT NULL,
    entity_type   TEXT,
    entity_id     INTEGER,
    summary       TEXT NOT NULL,
    payload_json  TEXT
  )
  ''',
  'CREATE INDEX idx_audit_log_business_date ON audit_log(business_date)',
  'CREATE INDEX idx_audit_log_action ON audit_log(action, at)',

  // ───────────────────────────── menu ─────────────────────────────
  '''
  CREATE TABLE product_categories (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    name          TEXT NOT NULL,
    display_order INTEGER NOT NULL DEFAULT 0,
    is_active     INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_product_categories_name ON product_categories(name COLLATE NOCASE)',

  // Customer-facing size name and its physical volume are stored separately:
  // the volume drives recipes, costing and reporting, the name drives the POS.
  '''
  CREATE TABLE sizes (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    code          TEXT NOT NULL,
    name          TEXT NOT NULL,
    volume_oz     REAL NOT NULL,
    display_order INTEGER NOT NULL DEFAULT 0,
    is_active     INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_sizes_code ON sizes(code)',

  '''
  CREATE TABLE products (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    category_id   INTEGER NOT NULL REFERENCES product_categories(id) ON DELETE RESTRICT,
    name          TEXT NOT NULL,
    description   TEXT,
    display_order INTEGER NOT NULL DEFAULT 0,
    is_active     INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    is_archived   INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
  )
  ''',
  'CREATE INDEX idx_products_category ON products(category_id, display_order)',
  'CREATE UNIQUE INDEX idx_products_name ON products(name COLLATE NOCASE)',

  // Price, availability and (via `recipes`) the recipe are per product+size.
  '''
  CREATE TABLE product_sizes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id      INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    size_id         INTEGER NOT NULL REFERENCES sizes(id) ON DELETE RESTRICT,
    price_centavos  INTEGER NOT NULL CHECK (price_centavos >= 0),
    is_available    INTEGER NOT NULL DEFAULT 1 CHECK (is_available IN (0, 1)),
    is_default_size INTEGER NOT NULL DEFAULT 0 CHECK (is_default_size IN (0, 1)),
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_product_sizes_unique ON product_sizes(product_id, size_id)',
  'CREATE INDEX idx_product_sizes_size ON product_sizes(size_id)',

  '''
  CREATE TABLE customization_groups (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    code           TEXT NOT NULL,
    name           TEXT NOT NULL,
    selection_type TEXT NOT NULL CHECK (selection_type IN ('single', 'multi')),
    min_select     INTEGER NOT NULL DEFAULT 0 CHECK (min_select >= 0),
    max_select     INTEGER CHECK (max_select IS NULL OR max_select > 0),
    is_required    INTEGER NOT NULL DEFAULT 0 CHECK (is_required IN (0, 1)),
    display_order  INTEGER NOT NULL DEFAULT 0,
    is_active      INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_customization_groups_code ON customization_groups(code)',

  '''
  CREATE TABLE customization_options (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    group_id             INTEGER NOT NULL REFERENCES customization_groups(id) ON DELETE CASCADE,
    name                 TEXT NOT NULL,
    description          TEXT,
    price_delta_centavos INTEGER NOT NULL DEFAULT 0,
    display_order        INTEGER NOT NULL DEFAULT 0,
    is_active            INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    created_at           TEXT NOT NULL,
    updated_at           TEXT NOT NULL
  )
  ''',
  'CREATE INDEX idx_customization_options_group ON customization_options(group_id, display_order)',
  'CREATE UNIQUE INDEX idx_customization_options_name ON customization_options(group_id, name COLLATE NOCASE)',

  // What an option does to the recipe. A negative delta is legitimate:
  // "No Sugar" can remove syrup that the base recipe includes.
  '''
  CREATE TABLE option_ingredient_effects (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    option_id       INTEGER NOT NULL REFERENCES customization_options(id) ON DELETE CASCADE,
    ingredient_id   INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE RESTRICT,
    qty_milli_delta INTEGER NOT NULL,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_option_effects_unique ON option_ingredient_effects(option_id, ingredient_id)',
  'CREATE INDEX idx_option_effects_ingredient ON option_ingredient_effects(ingredient_id)',

  // Which groups a product shows. `size_id IS NULL` means "for every size".
  '''
  CREATE TABLE product_customization_groups (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id           INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    size_id              INTEGER REFERENCES sizes(id) ON DELETE CASCADE,
    group_id             INTEGER NOT NULL REFERENCES customization_groups(id) ON DELETE CASCADE,
    is_visible           INTEGER NOT NULL DEFAULT 1 CHECK (is_visible IN (0, 1)),
    is_required_override INTEGER CHECK (is_required_override IS NULL OR is_required_override IN (0, 1)),
    min_select_override  INTEGER,
    max_select_override  INTEGER,
    display_order        INTEGER NOT NULL DEFAULT 0,
    created_at           TEXT NOT NULL,
    updated_at           TEXT NOT NULL
  )
  ''',
  '''
  CREATE UNIQUE INDEX idx_product_cust_groups_unique
    ON product_customization_groups(product_id, IFNULL(size_id, -1), group_id)
  ''',

  // Pre-selected options, so the common order is one tap.
  '''
  CREATE TABLE product_default_options (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    size_id    INTEGER REFERENCES sizes(id) ON DELETE CASCADE,
    option_id  INTEGER NOT NULL REFERENCES customization_options(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  ''',
  '''
  CREATE UNIQUE INDEX idx_product_defaults_unique
    ON product_default_options(product_id, IFNULL(size_id, -1), option_id)
  ''',

  // ─────────────────────── suppliers & ingredients ───────────────────────
  '''
  CREATE TABLE suppliers (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL,
    contact_person  TEXT,
    contact_details TEXT,
    notes           TEXT,
    is_active       INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_suppliers_name ON suppliers(name COLLATE NOCASE)',

  '''
  CREATE TABLE ingredients (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    name                     TEXT NOT NULL,
    category                 TEXT,
    base_unit                TEXT NOT NULL CHECK (base_unit IN ('g', 'ml', 'pcs')),
    purchase_unit_code       TEXT NOT NULL,
    purchase_unit_label      TEXT NOT NULL,
    purchase_unit_size_milli INTEGER NOT NULL CHECK (purchase_unit_size_milli > 0),
    is_inventory_tracked     INTEGER NOT NULL DEFAULT 1 CHECK (is_inventory_tracked IN (0, 1)),
    reorder_threshold_milli  INTEGER NOT NULL DEFAULT 0,
    critical_threshold_milli INTEGER NOT NULL DEFAULT 0,
    target_stock_milli       INTEGER NOT NULL DEFAULT 0,
    default_supplier_id      INTEGER REFERENCES suppliers(id) ON DELETE SET NULL,
    notes                    TEXT,
    is_active                INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
    created_at               TEXT NOT NULL,
    updated_at               TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_ingredients_name ON ingredients(name COLLATE NOCASE)',
  'CREATE INDEX idx_ingredients_supplier ON ingredients(default_supplier_id)',

  '''
  CREATE TABLE supplier_ingredients (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    supplier_id   INTEGER NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
    ingredient_id INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE,
    created_at    TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_supplier_ingredients_unique ON supplier_ingredients(supplier_id, ingredient_id)',

  // Every cost the business has ever paid, so historical margins stay honest.
  '''
  CREATE TABLE ingredient_cost_history (
    id                                 INTEGER PRIMARY KEY AUTOINCREMENT,
    ingredient_id                      INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE,
    unit_cost_centavos_per_1000_base   INTEGER NOT NULL CHECK (unit_cost_centavos_per_1000_base >= 0),
    effective_from                     TEXT NOT NULL,
    source                             TEXT NOT NULL CHECK (source IN ('purchase', 'manual', 'seed')),
    purchase_item_id                   INTEGER REFERENCES purchase_items(id) ON DELETE SET NULL,
    note                               TEXT,
    created_at                         TEXT NOT NULL
  )
  ''',
  '''
  CREATE INDEX idx_ingredient_cost_history_lookup
    ON ingredient_cost_history(ingredient_id, effective_from DESC)
  ''',

  // ───────────────────────── recipes & versions ─────────────────────────
  '''
  CREATE TABLE recipes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    size_id    INTEGER NOT NULL REFERENCES sizes(id) ON DELETE RESTRICT,
    notes      TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  ''',
  // One recipe per product+size. Small and Grande are independent: no recipe
  // is ever derived from another by a multiplier.
  'CREATE UNIQUE INDEX idx_recipes_unique ON recipes(product_id, size_id)',

  '''
  CREATE TABLE recipe_versions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    recipe_id      INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    version_no     INTEGER NOT NULL CHECK (version_no > 0),
    effective_from TEXT NOT NULL,
    effective_to   TEXT,
    status         TEXT NOT NULL CHECK (status IN ('draft', 'active', 'retired')),
    note           TEXT,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_recipe_versions_unique ON recipe_versions(recipe_id, version_no)',
  'CREATE INDEX idx_recipe_versions_effective ON recipe_versions(recipe_id, effective_from DESC)',

  '''
  CREATE TABLE recipe_items (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    recipe_version_id  INTEGER NOT NULL REFERENCES recipe_versions(id) ON DELETE CASCADE,
    ingredient_id      INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE RESTRICT,
    qty_milli          INTEGER NOT NULL CHECK (qty_milli >= 0),
    note               TEXT,
    created_at         TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_recipe_items_unique ON recipe_items(recipe_version_id, ingredient_id)',
  'CREATE INDEX idx_recipe_items_ingredient ON recipe_items(ingredient_id)',

  // ──────────────────────────── inventory ────────────────────────────
  // Cached running balance. The movement ledger below is the source of truth
  // and can rebuild this table at any time.
  '''
  CREATE TABLE inventory (
    ingredient_id INTEGER PRIMARY KEY REFERENCES ingredients(id) ON DELETE CASCADE,
    qty_milli     INTEGER NOT NULL DEFAULT 0,
    updated_at    TEXT NOT NULL
  )
  ''',

  '''
  CREATE TABLE inventory_movements (
    id                               INTEGER PRIMARY KEY AUTOINCREMENT,
    at                               TEXT NOT NULL,
    business_date                    TEXT NOT NULL,
    ingredient_id                    INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE RESTRICT,
    movement_type                    TEXT NOT NULL CHECK (movement_type IN
                                       ('sale', 'purchase', 'waste', 'adjustment',
                                        'correction', 'refund_reversal', 'void_reversal')),
    qty_milli_delta                  INTEGER NOT NULL,
    qty_before_milli                 INTEGER NOT NULL,
    qty_after_milli                  INTEGER NOT NULL,
    unit_cost_centavos_per_1000_base INTEGER NOT NULL DEFAULT 0,
    value_centavos                   INTEGER NOT NULL DEFAULT 0,
    reason                           TEXT,
    order_id                         INTEGER REFERENCES orders(id) ON DELETE SET NULL,
    order_item_id                    INTEGER REFERENCES order_items(id) ON DELETE SET NULL,
    purchase_item_id                 INTEGER REFERENCES purchase_items(id) ON DELETE SET NULL,
    waste_id                         INTEGER REFERENCES waste(id) ON DELETE SET NULL,
    stock_count_id                   INTEGER REFERENCES stock_counts(id) ON DELETE SET NULL,
    note                             TEXT
  )
  ''',
  'CREATE INDEX idx_inventory_movements_ingredient ON inventory_movements(ingredient_id, at DESC)',
  'CREATE INDEX idx_inventory_movements_date ON inventory_movements(business_date, movement_type)',
  'CREATE INDEX idx_inventory_movements_order ON inventory_movements(order_id)',

  '''
  CREATE TABLE stock_counts (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    counted_at    TEXT NOT NULL,
    business_date TEXT NOT NULL,
    is_applied    INTEGER NOT NULL DEFAULT 0 CHECK (is_applied IN (0, 1)),
    applied_at    TEXT,
    note          TEXT
  )
  ''',
  '''
  CREATE TABLE stock_count_items (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    stock_count_id INTEGER NOT NULL REFERENCES stock_counts(id) ON DELETE CASCADE,
    ingredient_id  INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE RESTRICT,
    expected_milli INTEGER NOT NULL,
    actual_milli   INTEGER NOT NULL,
    variance_milli INTEGER NOT NULL,
    note           TEXT
  )
  ''',
  'CREATE UNIQUE INDEX idx_stock_count_items_unique ON stock_count_items(stock_count_id, ingredient_id)',

  '''
  CREATE TABLE waste (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    at             TEXT NOT NULL,
    business_date  TEXT NOT NULL,
    ingredient_id  INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE RESTRICT,
    qty_milli      INTEGER NOT NULL CHECK (qty_milli > 0),
    reason         TEXT NOT NULL CHECK (reason IN
                     ('spill', 'spoiled', 'expired', 'wrong_prep', 'damaged', 'other')),
    value_centavos INTEGER NOT NULL DEFAULT 0,
    notes          TEXT
  )
  ''',
  'CREATE INDEX idx_waste_date ON waste(business_date)',
  'CREATE INDEX idx_waste_ingredient ON waste(ingredient_id, at DESC)',

  // ──────────────────────────── purchasing ────────────────────────────
  '''
  CREATE TABLE purchases (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    supplier_id    INTEGER REFERENCES suppliers(id) ON DELETE SET NULL,
    purchased_at   TEXT NOT NULL,
    business_date  TEXT NOT NULL,
    total_centavos INTEGER NOT NULL DEFAULT 0,
    notes          TEXT,
    created_at     TEXT NOT NULL
  )
  ''',
  'CREATE INDEX idx_purchases_date ON purchases(business_date)',
  'CREATE INDEX idx_purchases_supplier ON purchases(supplier_id)',

  '''
  CREATE TABLE purchase_items (
    id                               INTEGER PRIMARY KEY AUTOINCREMENT,
    purchase_id                      INTEGER NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
    ingredient_id                    INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE RESTRICT,
    qty_purchase_units               REAL NOT NULL,
    qty_milli                        INTEGER NOT NULL CHECK (qty_milli > 0),
    total_cost_centavos              INTEGER NOT NULL CHECK (total_cost_centavos >= 0),
    unit_cost_centavos_per_1000_base INTEGER NOT NULL CHECK (unit_cost_centavos_per_1000_base >= 0),
    note                             TEXT
  )
  ''',
  'CREATE INDEX idx_purchase_items_purchase ON purchase_items(purchase_id)',
  'CREATE INDEX idx_purchase_items_ingredient ON purchase_items(ingredient_id)',

  // ──────────────────────────── customers ────────────────────────────
  '''
  CREATE TABLE customers (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    name                   TEXT NOT NULL,
    mobile                 TEXT,
    created_at             TEXT NOT NULL,
    updated_at             TEXT NOT NULL,
    first_visit_at         TEXT,
    last_visit_at          TEXT,
    visit_count            INTEGER NOT NULL DEFAULT 0,
    order_count            INTEGER NOT NULL DEFAULT 0,
    item_count             INTEGER NOT NULL DEFAULT 0,
    total_spend_centavos   INTEGER NOT NULL DEFAULT 0,
    saved_usual_pattern_id INTEGER REFERENCES customer_order_patterns(id) ON DELETE SET NULL,
    segment                TEXT NOT NULL DEFAULT 'new'
                             CHECK (segment IN ('new', 'regular', 'frequent', 'vip', 'at_risk')),
    notes                  TEXT,
    is_active              INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1))
  )
  ''',
  'CREATE INDEX idx_customers_name ON customers(name COLLATE NOCASE)',
  'CREATE INDEX idx_customers_mobile ON customers(mobile)',
  'CREATE INDEX idx_customers_last_visit ON customers(last_visit_at DESC)',

  // One row per distinct drink configuration a customer has ordered.
  // `signature` is a stable hash of product + size + sorted option ids, so the
  // same drink always lands on the same row and the count is meaningful.
  '''
  CREATE TABLE customer_order_patterns (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id      INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    signature        TEXT NOT NULL,
    product_id       INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    size_id          INTEGER NOT NULL REFERENCES sizes(id) ON DELETE CASCADE,
    option_ids_json  TEXT NOT NULL,
    occurrence_count INTEGER NOT NULL DEFAULT 0,
    first_ordered_at TEXT NOT NULL,
    last_ordered_at  TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_customer_patterns_unique ON customer_order_patterns(customer_id, signature)',
  '''
  CREATE INDEX idx_customer_patterns_rank
    ON customer_order_patterns(customer_id, occurrence_count DESC, last_ordered_at DESC)
  ''',

  // ──────────────────────────── orders ────────────────────────────
  '''
  CREATE TABLE orders (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    order_no               TEXT NOT NULL,
    created_at             TEXT NOT NULL,
    business_date          TEXT NOT NULL,
    customer_id            INTEGER REFERENCES customers(id) ON DELETE SET NULL,
    customer_name_snapshot TEXT,
    status                 TEXT NOT NULL DEFAULT 'completed'
                             CHECK (status IN ('completed', 'voided')),
    subtotal_centavos      INTEGER NOT NULL DEFAULT 0,
    discount_centavos      INTEGER NOT NULL DEFAULT 0,
    total_centavos         INTEGER NOT NULL DEFAULT 0,
    cogs_centavos          INTEGER NOT NULL DEFAULT 0,
    gross_profit_centavos  INTEGER NOT NULL DEFAULT 0,
    refunded_centavos      INTEGER NOT NULL DEFAULT 0,
    item_count             INTEGER NOT NULL DEFAULT 0,
    note                   TEXT
  )
  ''',
  'CREATE UNIQUE INDEX idx_orders_order_no ON orders(order_no)',
  'CREATE INDEX idx_orders_business_date ON orders(business_date, status)',
  'CREATE INDEX idx_orders_customer ON orders(customer_id, created_at DESC)',

  // Snapshots (`*_snapshot`) exist so an order printed a year from now still
  // reads exactly as it was sold, even if the product was renamed or archived.
  '''
  CREATE TABLE order_items (
    id                           INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id                     INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    line_no                      INTEGER NOT NULL,
    product_id                   INTEGER REFERENCES products(id) ON DELETE SET NULL,
    product_name_snapshot        TEXT NOT NULL,
    category_name_snapshot       TEXT,
    size_id                      INTEGER REFERENCES sizes(id) ON DELETE SET NULL,
    size_name_snapshot           TEXT NOT NULL,
    size_volume_oz_snapshot      REAL NOT NULL,
    quantity                     INTEGER NOT NULL CHECK (quantity > 0),
    unit_base_price_centavos     INTEGER NOT NULL,
    unit_customization_centavos  INTEGER NOT NULL DEFAULT 0,
    unit_price_centavos          INTEGER NOT NULL,
    line_total_centavos          INTEGER NOT NULL,
    recipe_version_id            INTEGER REFERENCES recipe_versions(id) ON DELETE SET NULL,
    unit_cogs_centavos           INTEGER NOT NULL DEFAULT 0,
    line_cogs_centavos           INTEGER NOT NULL DEFAULT 0,
    refunded_quantity            INTEGER NOT NULL DEFAULT 0,
    note                         TEXT
  )
  ''',
  'CREATE INDEX idx_order_items_order ON order_items(order_id, line_no)',
  'CREATE INDEX idx_order_items_product ON order_items(product_id)',

  '''
  CREATE TABLE order_item_customizations (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    order_item_id        INTEGER NOT NULL REFERENCES order_items(id) ON DELETE CASCADE,
    group_id             INTEGER REFERENCES customization_groups(id) ON DELETE SET NULL,
    group_name_snapshot  TEXT NOT NULL,
    option_id            INTEGER REFERENCES customization_options(id) ON DELETE SET NULL,
    option_name_snapshot TEXT NOT NULL,
    price_delta_centavos INTEGER NOT NULL DEFAULT 0,
    display_order        INTEGER NOT NULL DEFAULT 0
  )
  ''',
  'CREATE INDEX idx_order_item_cust_item ON order_item_customizations(order_item_id, display_order)',

  // GCash is never `confirmed` automatically — the owner has to see the money.
  '''
  CREATE TABLE payments (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id           INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    method             TEXT NOT NULL CHECK (method IN ('cash', 'gcash')),
    amount_centavos    INTEGER NOT NULL,
    status             TEXT NOT NULL CHECK (status IN ('pending', 'confirmed')),
    reference_no       TEXT,
    tendered_centavos  INTEGER,
    change_centavos    INTEGER,
    created_at         TEXT NOT NULL,
    confirmed_at       TEXT
  )
  ''',
  'CREATE INDEX idx_payments_order ON payments(order_id)',
  'CREATE INDEX idx_payments_method ON payments(method, created_at)',

  '''
  CREATE TABLE refunds (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id          INTEGER NOT NULL REFERENCES orders(id) ON DELETE RESTRICT,
    at                TEXT NOT NULL,
    business_date     TEXT NOT NULL,
    amount_centavos   INTEGER NOT NULL CHECK (amount_centavos > 0),
    cogs_centavos     INTEGER NOT NULL DEFAULT 0,
    reason            TEXT NOT NULL,
    restock_inventory INTEGER NOT NULL DEFAULT 0 CHECK (restock_inventory IN (0, 1)),
    note              TEXT
  )
  ''',
  'CREATE INDEX idx_refunds_order ON refunds(order_id)',
  'CREATE INDEX idx_refunds_date ON refunds(business_date)',

  '''
  CREATE TABLE refund_items (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    refund_id       INTEGER NOT NULL REFERENCES refunds(id) ON DELETE CASCADE,
    order_item_id   INTEGER NOT NULL REFERENCES order_items(id) ON DELETE RESTRICT,
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    amount_centavos INTEGER NOT NULL,
    cogs_centavos   INTEGER NOT NULL DEFAULT 0
  )
  ''',
  'CREATE INDEX idx_refund_items_refund ON refund_items(refund_id)',

  // A void never deletes the sale; it records why it stopped counting.
  '''
  CREATE TABLE order_voids (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id        INTEGER NOT NULL REFERENCES orders(id) ON DELETE RESTRICT,
    at              TEXT NOT NULL,
    business_date   TEXT NOT NULL,
    amount_centavos INTEGER NOT NULL,
    reason          TEXT NOT NULL,
    note            TEXT
  )
  ''',
  'CREATE UNIQUE INDEX idx_order_voids_order ON order_voids(order_id)',
  'CREATE INDEX idx_order_voids_date ON order_voids(business_date)',

  '''
  CREATE TABLE daily_closings (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    business_date         TEXT NOT NULL,
    closed_at             TEXT NOT NULL,
    order_count           INTEGER NOT NULL DEFAULT 0,
    revenue_centavos      INTEGER NOT NULL DEFAULT 0,
    cash_centavos         INTEGER NOT NULL DEFAULT 0,
    gcash_centavos        INTEGER NOT NULL DEFAULT 0,
    cogs_centavos         INTEGER NOT NULL DEFAULT 0,
    gross_profit_centavos INTEGER NOT NULL DEFAULT 0,
    gross_margin_bp       INTEGER NOT NULL DEFAULT 0,
    waste_centavos        INTEGER NOT NULL DEFAULT 0,
    refunds_centavos      INTEGER NOT NULL DEFAULT 0,
    voids_centavos        INTEGER NOT NULL DEFAULT 0,
    note                  TEXT
  )
  ''',
  'CREATE UNIQUE INDEX idx_daily_closings_date ON daily_closings(business_date)',

  // Schema only. Discounts are switched off in V1 and the POS shows no
  // discount controls; the tables exist so enabling them later is a setting,
  // not a migration of live financial data.
  '''
  CREATE TABLE discounts (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    code           TEXT NOT NULL,
    name           TEXT NOT NULL,
    discount_type  TEXT NOT NULL CHECK (discount_type IN ('percent', 'amount')),
    value          INTEGER NOT NULL,
    is_active      INTEGER NOT NULL DEFAULT 0 CHECK (is_active IN (0, 1)),
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_discounts_code ON discounts(code)',
];
