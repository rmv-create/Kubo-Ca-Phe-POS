import 'package:sqflite_common/sqlite_api.dart';

import 'migration.dart';

/// Four things the owner asked for after using the POS, and one they imply.
///
/// **Payment methods become data.** V1 hard-coded Cash and GCash into an enum
/// and into a `CHECK` constraint on `payments.method`. The owner wants to add
/// and retire methods herself, so they move into a table. The constraint has
/// to go with them, which in SQLite means rebuilding `payments` — done here
/// once, carefully, copying every existing row.
///
/// **People and roles.** One operator became two: the owner, who sees the
/// business, and a barista, who sees the till. Sign-in is a PIN held as a
/// salted hash, never in the clear.
///
/// **Statutory discounts.** Senior Citizen and PWD discounts are not a
/// marketing promotion, they are law (RA 9994 and RA 10754): twenty per cent,
/// and for a VAT-registered seller the VAT comes off first. The establishment
/// must also record who claimed it. That is a different shape from the
/// promotional `discounts` table V1 shipped disabled, so it gets its own.
///
/// **VAT on the order.** Whether or not the shop is VAT-registered, an order
/// has to record what it assumed at the time, or a discount recomputed next
/// year will not match the receipt printed today.
class M003PaymentsPeopleAndDiscounts extends Migration {
  const M003PaymentsPeopleAndDiscounts();

  @override
  int get version => 3;

  @override
  String get name => 'payments_people_and_discounts';

  @override
  Future<void> up(DatabaseExecutor db) async {
    await _paymentMethods(db);
    await _rebuildPayments(db);
    await _people(db);
    await _orderTotals(db);
    await _statutoryDiscounts(db);
  }

  /// The methods the POS offers, in the order the buttons appear.
  Future<void> _paymentMethods(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE payment_methods (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        code                TEXT NOT NULL,
        name                TEXT NOT NULL,
        -- Money that lands somewhere the POS cannot see has to be confirmed by
        -- the person who can see it. That is what makes GCash different from
        -- cash, and it is a property of the method, not a special case.
        needs_confirmation  INTEGER NOT NULL DEFAULT 0
                              CHECK (needs_confirmation IN (0, 1)),
        takes_reference     INTEGER NOT NULL DEFAULT 0
                              CHECK (takes_reference IN (0, 1)),
        -- Cash is counted into a tin, so it can ask what was handed over and
        -- work out the change. Nothing else can.
        takes_tendered      INTEGER NOT NULL DEFAULT 0
                              CHECK (takes_tendered IN (0, 1)),
        is_active           INTEGER NOT NULL DEFAULT 1
                              CHECK (is_active IN (0, 1)),
        display_order       INTEGER NOT NULL DEFAULT 0,
        created_at          TEXT NOT NULL,
        updated_at          TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX idx_payment_methods_code ON payment_methods(code)',
    );

    // The two methods V1 hard-coded, with the behaviour it hard-coded for them.
    const String now = "datetime('now')";
    await db.execute('''
      INSERT INTO payment_methods
        (code, name, needs_confirmation, takes_reference, takes_tendered,
         is_active, display_order, created_at, updated_at)
      VALUES
        ('cash',  'Cash',  0, 0, 1, 1, 1, $now, $now),
        ('gcash', 'GCash', 1, 1, 0, 1, 2, $now, $now)
    ''');
  }

  /// Rebuilds `payments` without the `CHECK (method IN ('cash','gcash'))`.
  ///
  /// SQLite cannot drop a constraint in place. Nothing references `payments`,
  /// so the twelve-step rebuild reduces to: make the new shape, copy the rows,
  /// swap the names, put the indexes back.
  Future<void> _rebuildPayments(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE payments_new (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id            INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
        -- The method has to be one the shop actually offers. The reference
        -- also stops a method being deleted once it has taken money: SQLite
        -- refuses the delete, which is the rule we want enforced by the
        -- database rather than remembered by a screen.
        method              TEXT NOT NULL REFERENCES payment_methods(code),
        -- What the button said on the day. A method renamed from "GCash" to
        -- "GCash (personal)" must not rewrite last year's receipts.
        method_name_snapshot TEXT NOT NULL DEFAULT '',
        amount_centavos     INTEGER NOT NULL,
        status              TEXT NOT NULL CHECK (status IN ('pending', 'confirmed')),
        reference_no        TEXT,
        tendered_centavos   INTEGER,
        change_centavos     INTEGER,
        created_at          TEXT NOT NULL,
        confirmed_at        TEXT
      )
    ''');
    await db.execute('''
      INSERT INTO payments_new
        (id, order_id, method, method_name_snapshot, amount_centavos, status,
         reference_no, tendered_centavos, change_centavos, created_at, confirmed_at)
      SELECT
        p.id, p.order_id, p.method,
        CASE p.method WHEN 'cash' THEN 'Cash' WHEN 'gcash' THEN 'GCash' ELSE p.method END,
        p.amount_centavos, p.status, p.reference_no, p.tendered_centavos,
        p.change_centavos, p.created_at, p.confirmed_at
      FROM payments p
    ''');
    await db.execute('DROP TABLE payments');
    await db.execute('ALTER TABLE payments_new RENAME TO payments');
    await db.execute('CREATE INDEX idx_payments_order ON payments(order_id)');
    await db.execute(
      'CREATE INDEX idx_payments_method ON payments(method, created_at)',
    );
  }

  /// Who is signed in, and what they are allowed to see.
  Future<void> _people(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE app_users (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        name              TEXT NOT NULL,
        role              TEXT NOT NULL CHECK (role IN ('owner', 'barista')),
        -- Salted hash only. A PIN is short enough to brute-force offline, so
        -- this protects against a shoulder-glance at the database, not against
        -- someone who has the file. See the sign-in service for what this is
        -- and is not.
        pin_salt          TEXT NOT NULL,
        pin_hash          TEXT NOT NULL,
        is_active         INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
        created_at        TEXT NOT NULL,
        updated_at        TEXT NOT NULL,
        last_signed_in_at TEXT
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX idx_app_users_name ON app_users(name COLLATE NOCASE)',
    );

    // Which of them rang the sale. Nullable: every order taken before there
    // were users has no honest answer, and inventing one would be worse.
    await db.execute(
      'ALTER TABLE orders ADD COLUMN taken_by_user_id INTEGER '
      'REFERENCES app_users(id) ON DELETE SET NULL',
    );
    await db.execute('ALTER TABLE audit_log ADD COLUMN actor TEXT');
  }

  /// What an order records about tax, delivery and the discount applied.
  Future<void> _orderTotals(DatabaseExecutor db) async {
    // `discount_centavos` already exists from V1.
    const List<String> columns = <String>[
      // The VAT position assumed when this order was rung, so a receipt
      // reprinted after the shop registers for VAT still reads as it was sold.
      'vat_rate_bp INTEGER NOT NULL DEFAULT 0',
      'vat_centavos INTEGER NOT NULL DEFAULT 0',
      'vat_exempt_sales_centavos INTEGER NOT NULL DEFAULT 0',
      'net_of_vat_centavos INTEGER NOT NULL DEFAULT 0',
      'delivery_fee_centavos INTEGER NOT NULL DEFAULT 0',
    ];
    for (final String column in columns) {
      await db.execute('ALTER TABLE orders ADD COLUMN $column');
    }
  }

  /// Senior Citizen and PWD discounts, recorded the way the law requires.
  Future<void> _statutoryDiscounts(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE order_discounts (
        id                     INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id               INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
        kind                   TEXT NOT NULL
                                 CHECK (kind IN ('senior', 'pwd', 'other')),
        name                   TEXT NOT NULL,
        rate_bp                INTEGER NOT NULL DEFAULT 0,
        amount_centavos        INTEGER NOT NULL,
        -- The part of the sale that came out of VAT rather than out of margin.
        vat_exempt_centavos    INTEGER NOT NULL DEFAULT 0,
        -- RA 9994 and RA 10754 make the establishment record who claimed the
        -- discount. Blank is allowed so a sale is never blocked at the
        -- counter, but the receipt shows what is missing.
        beneficiary_name       TEXT,
        beneficiary_id_no      TEXT,
        created_at             TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_order_discounts_order ON order_discounts(order_id)',
    );
    await db.execute(
      'CREATE INDEX idx_order_discounts_kind ON order_discounts(kind, created_at)',
    );
  }
}
