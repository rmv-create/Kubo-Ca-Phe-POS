# Development workflow

## Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Flutter | 3.47.0 stable (Dart 3.10) | everything |
| Xcode | 16 or newer, on macOS | building, signing and running on iPhone/iPad |
| CocoaPods | latest | iOS dependencies |

Dart, static analysis and the **entire test suite** run on any platform —
Linux, Windows or macOS — because the database layer is tested through
`sqflite_common_ffi` rather than a device. Only the actual iOS build needs a
Mac.

## Everyday commands

```bash
flutter pub get                     # dependencies
flutter analyze                     # must be clean before every commit
flutter test                        # must be green before every commit
dart format lib test                # formatting, enforced in CI
dart fix --apply                    # apply mechanical lint fixes

flutter run -d "iPhone 16 Plus"     # primary device (macOS + Xcode)
flutter run -d "iPad Pro 11-inch"   # secondary device
flutter build ios --release --no-codesign
```

## Verification gate

Nothing is committed unless all three pass:

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

CI (`.github/workflows/ci.yml`) runs exactly these on Linux, plus an unsigned
iOS build on macOS — the one check a Linux machine cannot do itself.

## Trying it without a Mac

The production target is iOS, but the same code runs in a browser, which is
the quickest way to click through it and leave comments.

```bash
flutter pub get
dart run sqflite_common_ffi_web:setup      # once — fetches the SQLite wasm worker
flutter build web --release --no-web-resources-cdn
cd build/web && python3 -m http.server 8099
# then open http://localhost:8099
```

`--no-web-resources-cdn` keeps the renderer inside the build. Without it
Flutter fetches it from Google at run time, which would break the one promise
the app makes — that it works without internet.

The web build uses SQLite compiled to WebAssembly, stored in the browser. Same
schema, same migrations, same seed, same engines. The only thing it cannot do
is file backups, because a browser has no folder to write into.

### Publishing it for someone else to try

`.github/workflows/pages.yml` builds and publishes the web version to GitHub
Pages. Switch it on under repository **Settings → Pages → Source → GitHub
Actions**, then push to a branch the workflow watches.

Two things that catch people out:

* **Pages needs a paid plan on a private repo.** On the free plan the
  repository has to be public for the site to serve. Flipping it back to
  private takes the site down again, which is the normal way to end a test.
* **The workflow only offers a "Run workflow" button once it is on the default
  branch.** Until then a push to one of the branches it watches is what starts
  it.

The published link opens in Safari on an iPhone or iPad, and **Share → Add to
Home Screen** turns it into a full-screen app with the shop's mark as its
icon. Each device keeps its own database in its own browser — nothing syncs
between them, which is fine for trying the app out and is not how the real
product works.


## Repository layout

```
lib/         application code (see docs/ARCHITECTURE.md for the layer rules)
ios/         the single universal iPhone + iPad target
test/
  unit/      value types and pure logic — no database
  db/        schema, migrations, repositories — in-memory SQLite
  widget/    layout and rendering at real device sizes
  scenario/  end-to-end business flows (arrives with Phase 3)
  support/   shared test helpers
docs/        architecture, this file, and schema notes
```

## Branching

* `main` — always analyzable, testable and green.
* `claude/<topic>` — one branch per phase or fix. Small, reviewable commits.
* Commit messages: imperative summary, then *what changed and why*, then the
  verification that was actually run.

Never commit:

* real business data (prices, recipes, ingredient costs, customer records) —
  see [Sample data](#sample-data);
* `*.db` files, backups, or anything under `/backups/`;
* generated build output.

## Phase workflow

The app is built in the eight phases listed in `docs/ARCHITECTURE.md`. For each
phase, in this order:

1. State what the phase will implement.
2. Implement it.
3. Write tests **for that phase's rules**, not just for its code paths.
4. Run analyze + the full suite; check for regressions in earlier phases.
5. Describe the database changes (new migration number, new tables/columns).
6. List the files changed.
7. Report which tests were run and what they cover.
8. Report known issues and anything deliberately left out.

A phase is not "done" while any of its tests are red or any of its screens are
placeholders.

## Database changes

Migrations are **append-only**. To change the schema:

1. Add `lib/data/db/migrations/mNNN_<name>.dart` with the next version number.
2. Register it in `appMigrations` in `migration_runner.dart`.
3. Add a test in `test/db/` that proves both a fresh install and an upgrade
   from the previous version end up with the same schema.

Never edit a released migration, and never fix a schema problem by deleting the
database — the owner's customers, orders, inventory and costs must survive
every update. A backup is taken automatically before any migration runs.

## Money and quantities

* Money is **integer centavos** (`Money`). Never `double`, never `num`.
* Ingredient amounts are **integer milli-base-units** (`Quantity`): thousandths
  of a gram, millilitre or piece.
* Ingredient costs are **integer centavos per 1000 base units** (`UnitCost`),
  so ₱90/L is exactly `9000` and not a rounding error.
* Recipe costing accumulates in micro-centavos and rounds **once**, at the
  order-item level, half away from zero.

A test that asserts a peso figure must assert an exact `Money`, never a
tolerance.

## Sample data

Any seeded product, price, recipe, ingredient or cost is **sample data** and is
labelled as such in code and in the UI. Real values come from the owner. Do not
invent a plausible-looking price and let it look official.
