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

| Delivery | Scope | State |
|---|---|---|
| 1 | Foundation: project, iOS/iPad target, SQLite, migrations, architecture, shell, settings, backup | **Done** |
| 2 | Setup & Menu: categories, sizes, products, prices, customisation groups and options, per-product rules, defaults — all editable in the app | Next |
| 3 | POS: customers, the usual order, order building, cash/GCash, atomic order completion | Not started |
| 4 | Costing & Stock: ingredients, recipes and versions, cost history, inventory, purchases, suppliers, waste | Not started |
| 5 | Controls & Reports: refunds, voids, audit trail, daily closing, reporting, Excel exports | Not started |

Everything the business is — menu, prices, sizes, customisations, recipes, ingredients,
costs, thresholds, suppliers — is **data, not code**. The owner sets all of it up in the
app herself; no source change is needed to add a drink, change a price, or rewrite a
recipe. `docs/Kubo Ca Phe - POS Setup.xlsx` is an optional worksheet for gathering that
information away from the phone.

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
