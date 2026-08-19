# Kubo Cà Phê POS

Offline-first point-of-sale and business management app for a one-person,
home-based coffee shop in the Philippines. One Flutter codebase, built for
**iPhone 16 Plus** (primary) and **iPad** (secondary).

Everything is local: SQLite on the device, no cloud service, no internet
required to take an order, cost it, deduct stock or close the day.

Currency is the **Philippine Peso (PHP, ₱)**, held as integer centavos so
totals never drift.

## What it does

Take the order once, and the app derives the rest — revenue, recipe, COGS,
gross profit, inventory deduction, customer history and reporting — without the
owner entering anything twice.

## Status

Built in phases. See `docs/ARCHITECTURE.md` for the full design and
`docs/DEVELOPMENT.md` for how to build, test and contribute.

| Phase | Scope | State |
|---|---|---|
| 1 | Foundation: project, iOS/iPad target, SQLite, migrations, architecture, shell, settings, backup | **Done** |
| 2 | Menu: categories, products, Small/Grande sizes and prices, customisations | Not started |
| 3 | POS: customers, order building, cash/GCash, atomic order completion | Not started |
| 4 | Customers and the "usual" order | Not started |
| 5 | Ingredients, recipes, versioning, costing | Not started |
| 6 | Inventory, purchases, suppliers, waste | Not started |
| 7 | Refunds, voids, audit trail, daily closing | Not started |
| 8 | Reporting and Excel exports | Not started |

## Quick start

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d "iPhone 16 Plus"   # requires macOS + Xcode
```

## A note on data

No product price, recipe quantity, ingredient cost or supplier in this
repository is real. Anything seeded is clearly marked sample data. The real
figures come from the owner — see the open questions at the end of
`docs/ARCHITECTURE.md`.
