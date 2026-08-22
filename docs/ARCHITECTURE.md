# Kubo Cà Phê POS — Architecture Review

> **Status:** Approved baseline for Phase 1.
> **Currency:** Philippine Peso (PHP, ₱), 2 decimal places, stored as integer centavos.
> **Platforms:** iOS (iPhone 16 Plus — primary) and iPadOS (secondary). One Flutter codebase.
> **Database:** SQLite (local, offline-first). No cloud dependency in V1.

---

## A. Project structure

Layered + feature-first. Business rules never live in widgets; screens never touch SQL.

```
lib/
  main.dart                    App entry, DI bootstrap, DB open, migrations, backup check
  app/
    app.dart                   Root widget (MaterialApp.router)
    router.dart                GoRouter routes + responsive shell
    theme/                     Design tokens: color, type, spacing, radius, elevation
    responsive/                Breakpoints + Layout.of(context) form-factor resolution
  core/
    money/                     Money (integer centavos) + PHP formatting
    quantity/                  Quantity (integer milli-base-units) + unit conversion
    result/                    Result<T> / AppFailure
    time/                      Clock abstraction (testable "now", business-date logic)
    errors/                    Typed exceptions + error logging
  data/
    db/
      app_database.dart        Open, PRAGMAs, transaction helper, ffi/native factory
      migrations/              m001_initial.dart ... + MigrationRunner
      seed/                    DEMO seed data (clearly flagged as sample)
    dao/                       Thin SQL data-access objects (one per aggregate)
    repositories/              Repository implementations (map rows <-> entities)
  domain/
    entities/                  Immutable models (Product, Recipe, Order, Ingredient, ...)
    repositories/              Abstract repository interfaces (domain owns the contract)
    services/
      pricing_engine.dart      base price + customization deltas -> line + order totals
      costing_engine.dart      recipe + customizations -> COGS, gross profit, margin
      inventory_engine.dart    consumption calculation + ledger posting
      usual_order_engine.dart  order-pattern signature, ranking, usual resolution
      order_service.dart       COMPLETE ORDER — single atomic transaction
      closing_service.dart     daily closing totals + lock
      audit_service.dart       audit_log writes
  features/
    pos/  customers/  menu/  recipes/  ingredients/  inventory/
    waste/  suppliers/  purchases/  reports/  closing/  settings/  backup/
        presentation/          Screens + widgets (phone/tablet variants)
        state/                 Riverpod controllers (Notifier / AsyncNotifier)
  shared/brand/                The logo mark as vector outline data
  shared/widgets/              Reusable UI: KuboButton, SectionHeader, MoneyText, ...
ios/                           iOS + iPadOS target (single target, universal)
test/
  unit/                        Money, Quantity, engines, repositories (ffi in-memory DB)
  db/                          Migration + schema integrity tests
  scenario/                    End-to-end business scenarios (§84 of the brief)
docs/                          This document + schema notes + dev workflow
```

**Dependency direction:** `features → domain → (interfaces)`; `data` implements domain
interfaces. `domain` imports nothing from `data` or `features`.

---

## B. Database schema (V1, migration `m001`)

All money is `INTEGER` **centavos**. All ingredient quantities are `INTEGER`
**milli-base-units** (1/1000 of g, ml, or pcs). All timestamps are `TEXT` ISO-8601 UTC,
plus a denormalized `business_date` (`TEXT 'YYYY-MM-DD'`, local) on transactional tables
for fast day reporting.

### Reference / settings
| Table | Purpose |
|---|---|
| `app_settings` | key/value: business name, currency (PHP), costing method, day cutoff, backup retention, schema version |
| `audit_log` | id, at, business_date, action, entity_type, entity_id, summary, payload_json |

### Menu
| Table | Key columns |
|---|---|
| `product_categories` | id, name, display_order, is_active |
| `sizes` | id, code, name (`Small`), volume_oz (REAL), display_order, is_active |
| `products` | id, category_id→, name, description, display_order, is_active, is_archived |
| `product_sizes` | id, product_id→, size_id→, price_centavos, is_available, is_default_size — UNIQUE(product_id, size_id) |
| `customization_groups` | id, code, name, selection_type(`single`/`multi`), min_select, max_select, is_required, display_order, is_active |
| `customization_options` | id, group_id→, name, price_delta_centavos, display_order, is_active |
| `option_ingredient_effects` | id, option_id→, ingredient_id→, qty_milli_delta (may be negative) |
| `product_customization_groups` | id, product_id→, size_id (NULL = all sizes), group_id→, is_visible, is_required_override, min/max override, display_order |
| `product_default_options` | id, product_id→, size_id (NULL = all), option_id→ |

> Customization availability is **per product and optionally per size** (§13). Nothing is
> hard-coded in a screen.

### Ingredients, recipes, costing
| Table | Key columns |
|---|---|
| `ingredients` | id, name, category, base_unit(`g`/`ml`/`pcs`), purchase_unit, purchase_unit_size_milli, is_inventory_tracked, reorder_threshold_milli, critical_threshold_milli, target_stock_milli, default_supplier_id→, notes, is_active |
| `ingredient_cost_history` | id, ingredient_id→, unit_cost_centavos_per_1000_base, effective_from, source(`purchase`/`manual`/`seed`), purchase_item_id→ (nullable), note |
| `recipes` | id, product_id→, size_id→ — UNIQUE(product_id, size_id) |
| `recipe_versions` | id, recipe_id→, version_no, effective_from, effective_to (NULL = current), status(`draft`/`active`/`retired`), note |
| `recipe_items` | id, recipe_version_id→, ingredient_id→, qty_milli |

> **Small and Grande are independent recipes** (§38). No multiplier is ever applied.
> Cost unit: centavos per **1000 base units** (i.e. per kg / per L / per 1000 pcs), which
> keeps cheap ingredients (milk at ₱0.09/ml) representable in integers.

### Inventory
| Table | Key columns |
|---|---|
| `inventory` | ingredient_id→ (PK), qty_milli, updated_at — cached balance |
| `inventory_movements` | id, at, business_date, ingredient_id→, movement_type(`sale`/`purchase`/`waste`/`adjustment`/`correction`/`refund_reversal`/`void_reversal`), qty_milli_delta, qty_before_milli, qty_after_milli, unit_cost_centavos_per_1000_base, value_centavos, reason, order_id→, order_item_id→, purchase_item_id→, waste_id→, stock_count_id→, note |
| `stock_counts` / `stock_count_items` | physical count header + expected/actual/variance per ingredient, `is_applied` |
| `waste` | id, at, business_date, ingredient_id→, qty_milli, reason(`spill`/`spoiled`/`expired`/`wrong_prep`/`damaged`/`other`), value_centavos, notes |

> The **movement ledger is the source of truth**; `inventory.qty_milli` is a cache written
> in the same transaction. A rebuild-from-ledger routine exists for repair.

### Suppliers & purchasing
`suppliers` (name, contact_person, contact_details, notes, is_active) ·
`supplier_ingredients` (supplier_id→, ingredient_id→) ·
`purchases` (supplier_id→, purchased_at, business_date, total_centavos, notes) ·
`purchase_items` (purchase_id→, ingredient_id→, qty_purchase_units, qty_milli, total_cost_centavos, unit_cost_centavos_per_1000_base)

Purchases post `purchase` movements **and** append to `ingredient_cost_history`.

### Customers
| Table | Key columns |
|---|---|
| `customers` | id, name, mobile, created_at, last_visit_at, visit_count, order_count, total_spend_centavos, saved_usual_pattern_id→, segment(`new`/`regular`/`frequent`/`vip`/`at_risk`), is_active |
| `customer_order_patterns` | id, customer_id→, signature (hash of product+size+sorted options), product_id→, size_id→, options_json, occurrence_count, first_ordered_at, last_ordered_at — UNIQUE(customer_id, signature) |

### Transactions
| Table | Key columns |
|---|---|
| `orders` | id, order_no, created_at, business_date, customer_id→ (NULL = guest), status(`completed`/`voided`), subtotal_centavos, discount_centavos (always 0 in V1), total_centavos, cogs_centavos, gross_profit_centavos, refunded_centavos, note |
| `order_items` | id, order_id→, line_no, product_id→, **product_name_snapshot**, size_id→, **size_name_snapshot**, **size_volume_oz_snapshot**, quantity, unit_base_price_centavos, unit_customization_centavos, unit_price_centavos, line_total_centavos, recipe_version_id→, unit_cogs_centavos, line_cogs_centavos |
| `order_item_customizations` | id, order_item_id→, group_id→, **group_name_snapshot**, option_id→, **option_name_snapshot**, price_delta_centavos |
| `payments` | id, order_id→, method(`cash`/`gcash`), amount_centavos, status(`pending`/`confirmed`), reference_no, tendered_centavos, change_centavos, confirmed_at |
| `refunds` | id, order_id→, at, business_date, amount_centavos, reason, restock_inventory (0/1), note |
| `refund_items` | refund_id→, order_item_id→, quantity |
| `order_voids` | id, order_id→, at, business_date, amount_centavos, reason |
| `daily_closings` | id, business_date UNIQUE, closed_at, order_count, revenue, cash, gcash, cogs, gross_profit, gross_margin_bp, waste_value, refunds, voids, note |
| `discounts` | schema present, **disabled in V1** (§63) — no POS controls |

**Integrity:** `PRAGMA foreign_keys = ON`, `journal_mode = WAL`, `synchronous = FULL`.
Indexes on every FK, plus `orders(business_date)`, `orders(customer_id)`,
`inventory_movements(business_date)`, `inventory_movements(ingredient_id, at)`,
`customers(mobile)`, `customers(name COLLATE NOCASE)`,
`customer_order_patterns(customer_id, occurrence_count DESC)`.
Unique: `orders.order_no`, `daily_closings.business_date`, `(product_id,size_id)` in
`product_sizes` and `recipes`, `(recipe_version_id, ingredient_id)` in `recipe_items`.

---

## C. Entity relationships

```
product_categories 1─n products 1─n product_sizes n─1 sizes
                                     └─ 1:1 recipes 1─n recipe_versions 1─n recipe_items n─1 ingredients
products n─n customization_groups (via product_customization_groups, size-aware)
customization_groups 1─n customization_options 1─n option_ingredient_effects n─1 ingredients
ingredients 1─1 inventory · 1─n inventory_movements · 1─n ingredient_cost_history
suppliers n─n ingredients (supplier_ingredients) · suppliers 1─n purchases 1─n purchase_items
customers 1─n orders · customers 1─n customer_order_patterns (0..1 saved as "usual")
orders 1─n order_items 1─n order_item_customizations
orders 1─n payments · 1─n refunds · 0..1 order_voids
orders/order_items 1─n inventory_movements (traceable consumption)
```

Every completed `order_item` pins a `recipe_version_id` **and** stores its own
`unit_cogs_centavos`, so later recipe edits or ingredient price changes can never rewrite
historical profitability (§43, §44, §78, §79).

---

## D. State management

**Riverpod** (`flutter_riverpod`), hand-written `Notifier`/`AsyncNotifier` — no build_runner,
so the toolchain stays light and the build stays debuggable.

- **Providers for infrastructure:** `databaseProvider`, `clockProvider`, each repository, each
  domain service. Every one is overridable in tests with an in-memory FFI database.
- **`CartController` (`NotifierProvider`)** holds the in-progress order: draft items,
  selected customer, payment intent. Pure in-memory, zero DB writes until COMPLETE ORDER.
  Both the iPhone and iPad POS read the *same* controller — the layouts differ, the state
  does not.
- **`AsyncNotifier` for query-backed screens** (menu, inventory, reports), invalidated by a
  lightweight `dataChangedProvider` bus that `OrderService` pings after a commit.
- Widgets receive entities and callbacks. **No arithmetic in `build()`** — pricing/costing
  always comes from the engines.

---

## E. POS navigation flow

```
POS (home, no login)
├─ Customer strip ──► Search sheet ──► [Use Usual] ─────────────────► Cart
│                                   ├─ [Use Usual + Modify] ► Config ► Cart
│                                   ├─ [New customer] (name + mobile) ► Cart
│                                   └─ [Guest] ──────────────────────► Cart
├─ Category tabs ► Product tile ──► Product config sheet
│                                     Size ▸ Milk ▸ Ice ▸ Syrup ▸ Extras ▸ [ADD]
│                                     (defaults pre-selected — "Fast add" = tap size + ADD)
├─ Cart strip (always visible) ► Order review (edit / dup / ± qty / remove)
└─ [CASH] / [GCASH] ► GCash requires explicit "Payment received" ► [COMPLETE ORDER]
        └─► atomic commit ─► toast ─► immediately back to empty POS
Management (separate area, one tap from POS header)
└─ Dashboard · Orders · Customers · Menu · Recipes · Ingredients · Inventory
   · Waste · Suppliers · Purchases · Reports · Daily Closing · Settings · Backup
```

Fastest paths, measured in taps after the app is open:
- **Returning customer, usual:** search → tap customer → USE USUAL → CASH → COMPLETE (5)
- **New drink with defaults:** product → GRANDE → ADD → CASH → COMPLETE (5)

The POS screen never shows suppliers, analytics, recipe editing, or backup (§18).

---

## F. iPhone 16 Plus layout strategy

Logical canvas 430 × 932 pt. Single-column, vertically zoned, **thumb-first**.

```
┌───────────────────────────────┐
│ ☕ Kubo   ·  Guest / Customer │  56pt header, ⚙ opens Management
├───────────────────────────────┤
│ [ Classics ] [ Specialty ]    │  44pt sticky category chips
│ ┌─────────┐ ┌─────────┐       │
│ │ BLACK   │ │ SPANISH │  ...  │  2-col grid, 96pt tiles, big type
│ └─────────┘ └─────────┘       │  (scrolls)
├───────────────────────────────┤
│ 2 items                ₱XXX   │  persistent cart strip, tap = review
│ [   CASH   ] [   GCASH   ]    │  56pt payment buttons
│ [      COMPLETE ORDER     ]   │  64pt primary, thumb zone
└───────────────────────────────┘
```

- Product configuration opens as a **draggable bottom sheet**, not a pushed route — the cart
  stays one gesture away and dismissal is a swipe.
- Minimum touch target 48×48; primary actions 56–64pt tall.
- Cart total and COMPLETE never scroll out of reach.
- Dynamic Type honoured up to XXL; layout uses `Wrap`/`Flexible`, never fixed text boxes.

## G. iPad layout strategy

Three panes at ≥900pt width — no modal sheets, no navigation for a normal order.

```
┌────────────┬─────────────────────────┬────────────────┐
│ Categories │  Products / Config      │ CURRENT ORDER  │
│ Classics   │  ┌────┐┌────┐┌────┐     │ 1× Gr Spanish  │
│ Specialty  │  │    ││    ││    │     │   Oat·Less Ice │
│ ───────    │  └────┘└────┘└────┘     │           ₱XXX │
│ Customer   │  Size / Milk / Ice /    │ ────────────── │
│ Management │  Syrup / Extras inline  │ Total    ₱XXX  │
│            │  [ ADD TO ORDER ]       │ [CASH][GCASH]  │
│            │                         │ [ COMPLETE   ] │
└────────────┴─────────────────────────┴────────────────┘
```

- Portrait (768–899pt): two panes — products + cart; categories collapse to a rail.
- Management screens gain master–detail (list left, editor right) instead of push navigation.
- **Identical controllers, repositories, engines, and database.** Only widget composition
  differs, selected by `Layout.of(context).formFactor` (`compact` / `medium` / `expanded`).

---

## H. Recipe / costing architecture

```
OrderDraftItem(product, size, quantity, options[])
   │
   ├─ PricingEngine
   │     unit_price = product_sizes.price + Σ option.price_delta
   │     line_total = unit_price × quantity                       → centavos (exact ints)
   │
   └─ CostingEngine
         recipe_version = active version of recipes(product,size) at order time
         consumption[ingredient] = Σ recipe_items.qty_milli
                                 + Σ option_ingredient_effects.qty_milli_delta
         unit_cost(ingredient)   = per costing method, as of order time
                                   (`latest` default | `weighted_average` — a setting)
         unit_cogs (µcentavos)   = Σ qty_milli × unit_cost_per_1000_base
                                   ────────────────────────────────────  (integer math)
                                                  1000
         → summed across ingredients, rounded HALF-UP once to centavos
         gross_profit = line_total − line_cogs
         gross_margin = gross_profit / line_total    (stored as basis points)
```

Called **gross profit**, never net profit (§42). Both the recipe version id and the resolved
COGS are written onto the order item, so the number is reproducible forever.
`SupplierPriceImpact` reads `ingredient_cost_history` and reports which products' COGS moved
when an ingredient price changed (§60).

## I. Inventory architecture

Every stock change is a **ledger entry**, never a bare UPDATE:

```
InventoryEngine.post(movements[], txn)
  for each movement:
     before = inventory.qty_milli (SELECT ... inside the same txn)
     after  = before + delta
     INSERT inventory_movements(before, after, type, reason, source refs, value)
     UPDATE inventory SET qty_milli = after
```

- **Sale:** `OrderService` computes consumption from recipe + customizations and posts
  negative movements linked to `order_item_id`. Ingredients with
  `is_inventory_tracked = 0` (e.g. Ice, §41) are **costed but not deducted** — the flag flips
  later with no code change.
- **Purchase / waste / adjustment / stock count** post their own typed movements.
- **Refund** posts `refund_reversal`, **void** posts `void_reversal` (§61, §62) — the original
  sale rows are never deleted.
- **Stock count** shows expected vs actual vs variance and only writes after explicit
  confirmation (§52).
- Alerts: `qty ≤ critical_threshold` → CRITICAL (red + icon + label), `qty ≤ reorder_threshold`
  → LOW (amber + icon + label). Never colour alone (§74).

## J. Backup architecture

- Location: `<AppDocuments>/backups/kubo_YYYYMMDD_HHmmss[_reason].db`.
- Triggers: **before every migration**, before restore, before applying a stock count or
  restore-risky op, on daily closing, and on a rolling automatic schedule (first launch of
  each day).
- WAL is checkpointed (`PRAGMA wal_checkpoint(TRUNCATE)`) before copying so the single file
  is complete and consistent.
- Retention keeps the newest N (setting, default 14) **and always preserves at least one**
  backup plus the most recent pre-migration backup — the only backup is never overwritten (§68).
- Restore: integrity-check the candidate → back up current → swap → reopen → re-run migrations.
- Manifest (`backups/manifest.json`) records timestamp, reason, schema version, size, sha256.
- No cloud requirement. The file is exportable via the iOS share sheet.

## K. Testing strategy

| Layer | Tool | Coverage |
|---|---|---|
| Value types | `flutter test` | Money arithmetic, rounding, `₱1,250.50` formatting, no float drift |
| Units | `flutter test` | g/kg/ml/L/pcs/carton conversion, milli-unit round-trips |
| Schema | ffi in-memory DB | Migration runs clean, FK enforcement, constraint violations, idempotency |
| Engines | ffi in-memory DB | Pricing, COGS, gross profit/margin, inventory math, usual-order ranking |
| Scenarios | ffi in-memory DB | The §84 script: Maria orders Grande → Small → guest → cash → GCash → refund → void → waste → ingredient price change → recipe version change → duplicate item |
| Atomicity | ffi in-memory DB | Forced mid-commit failure leaves **zero** partial rows |
| Widget | `flutter test` | POS renders at 430pt and 1024pt; usual/fast-add tap counts |

`flutter analyze` clean + `flutter test` green is the gate for every commit.
All test data is explicitly labelled sample/demo (§85).

---

## L. Risks

1. **No macOS/Xcode in this environment.** Dart, analysis, and the full test suite run here;
   the actual iOS build, signing, simulator run, and device deployment must happen on a Mac.
   The `ios/` target is generated and committed, but *unverified against Xcode* until then.
2. **Single-file SQLite + one device = one point of failure.** Mitigated by scheduled backups
   and manifest verification; an off-device copy is still the owner's responsibility in V1.
3. **Costing method choice materially changes reported margins.** Latest-cost is the default
   because it is intuitive; weighted-average is a setting. This needs an explicit decision.
4. **Rounding.** Fixed by integer centavos end-to-end and a single half-up rounding point per
   order item — but any later discount/VAT feature must reuse the same rules.
5. **"Usual" quality depends on data volume.** With <2 repeats there is no usual; the UI shows
   "no usual yet" rather than guessing from a single order.
6. **Business-date boundary.** A drink sold at 00:30 belongs to which day? Configurable cutoff
   (default 04:00 local) — needs the owner's answer.
7. **Scope creep.** The brief lists 8 phases; each will be delivered, tested, and reported
   separately rather than in one pass (§89).

## M. Business decisions still needing real data

Nothing below is invented. Everything shipped in seed data is flagged **SAMPLE**.

| # | Needed from the owner |
|---|---|
| 1 | Selling price for every product × Small/Grande |
| 2 | Exact recipe per product × size: ingredient, quantity, unit (Small and Grande separately) |
| 3 | Real ingredient list and naming (bean type, milk brands, syrups, sauces, packaging) |
| 4 | Ingredient purchase units and current costs (₱ per kg / L / pack / carton) |
| 5 | Final customization options per product, and which are valid for which product/size |
| 6 | Customization price adjustments (+₱) and their ingredient consumption (+ml/+g) |
| 7 | Default size / milk / ice / sweetness per product |
| 8 | Packaging: cup sizes, lids, straws, sleeves — and whether each is inventory-tracked |
| 9 | Reorder + critical thresholds and target stock per ingredient |
| 10 | Suppliers and which ingredients each supplies |
| 11 | Opening inventory quantities |
| 12 | Costing method: latest cost vs weighted average |
| 13 | Business day cutoff time; order-number format and daily reset behaviour |
| 14 | Business name exactly as it should print on reports/exports |
| 15 | Whether Ice (and any other untracked item) should be costed even while untracked |
