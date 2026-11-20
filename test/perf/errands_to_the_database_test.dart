import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/database_archive.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/services/moving_average_cost.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/pos_fixture.dart';

/// How many separate errands the app sends to the database.
///
/// On this machine every one of them is a function call and costs nothing
/// worth measuring. In her sister's phone the database is SQLite compiled to
/// WebAssembly, living behind a worker, and every statement is a message
/// sent and a message waited for. A hundred statements is a hundred of those
/// round trips, one after another, on the thread that is also drawing the
/// screen — which is what "it hangs when I take a payment" was.
///
/// So this counts them. The numbers are not a speed limit; they are a guard
/// against the kind of change that quietly turns one question into a hundred
/// — asking the price of the same milk once per drink per movement, or
/// rebuilding the whole pantry's costs after every sync.
///
/// When these fail, nothing is broken. Look at what was added and ask
/// whether it could be one question instead of many.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  int errands = 0;
  late DatabaseFactory counting;

  setUp(() {
    sqfliteFfiInit();
    errands = 0;
    // The logger is marked experimental upstream; it is only ever used
    // here, to count, and never in the app itself.
    // ignore: experimental_member_use
    counting = SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.invoke,
        log: (SqfliteLoggerEvent event) => errands++,
      ),
    );
  });

  test('ringing up two drinks', () async {
    final PosFixture shop = await PosFixture.open(factory: counting);
    addTearDown(shop.close);
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();

    // One sale first, so nothing below is paying for a cold start.
    await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    final DraftItem one = await shop.item(
      'Spanish Latte',
      'Large',
      lineId: 'a',
    );
    final DraftItem two = await shop.item(
      'Caramel Macchiato',
      'Small',
      lineId: 'b',
    );

    errands = 0;
    await shop.sell(
      OrderDraft(
        items: <DraftItem>[one, two],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    // Measured at 18. It was 184 before the same milk stopped being priced
    // once per drink and once per movement, and before the stock ledger was
    // written in one go instead of four statements per ingredient.
    expect(
      errands,
      lessThan(40),
      reason: 'completing an order should not be a hundred errands',
    );
  });

  test('rebuilding what the shelf cost', () async {
    final PosFixture shop = await PosFixture.open(factory: counting);
    addTearDown(shop.close);
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
    for (int i = 0; i < 5; i++) {
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[
            await shop.item('Spanish Latte', 'Large', lineId: 'x$i'),
          ],
          paymentMethod: PaymentMethod.cash,
        ),
      );
    }

    errands = 0;
    await const MovingAverageCost().rebuildAll(shop.db.db);

    // Three questions and one answer, whatever the pantry holds. It used to
    // be four per ingredient, and it runs after every sync.
    expect(
      errands,
      lessThan(20),
      reason: 'the whole pantry at once, not ingredient by ingredient',
    );
  });

  group('telling the other till', () {
    late PosFixture her;
    late PosFixture other;
    late SyncEngine hers;
    late SyncEngine theirs;

    setUp(() async {
      her = await PosFixture.open(separate: true, factory: counting);
      other = await PosFixture.open(separate: true, factory: counting);
      await PantrySeeder(her.db, her.clock).seedIfEmpty();
      await PantrySeeder(other.db, other.clock).seedIfEmpty();
      await DatabaseArchive(
        other.db.db,
        other.clock,
      ).restore(await DatabaseArchive(her.db.db, her.clock).export());
      await other.db.db.delete('sync_outbox');
      hers = SyncEngine(database: her.db, clock: her.clock);
      theirs = SyncEngine(database: other.db, clock: other.clock);
      // Both start level, so what is counted below is ten orders and
      // nothing else.
      await hers.collect().then(hers.markSent);
    });
    tearDown(() async {
      await her.close();
      await other.close();
    });

    test('ten orders, gathered up and handed over', () async {
      for (int i = 0; i < 10; i++) {
        await her.sell(
          OrderDraft(
            items: <DraftItem>[
              await her.item('Spanish Latte', 'Large', lineId: 'x$i'),
            ],
            paymentMethod: PaymentMethod.cash,
          ),
        );
      }

      errands = 0;
      final List<SyncChange> mine = await hers.collect();
      final int gathering = errands;
      expect(mine.length, greaterThan(100));

      errands = 0;
      await theirs.apply(mine);
      final int applying = errands;

      // Measured at 36. It was 496: one question for every row's uid and
      // another for the row itself, the same ingredient looked up ten times
      // over.
      expect(
        gathering,
        lessThan(120),
        reason: 'one question per table, not per row',
      );

      // Measured at 409 for 110 changes — roughly three per change, which
      // is a look, a write and a note that it has been seen. It was 1106,
      // because every order arrived before its own lines and the whole
      // batch had to be tried twice.
      expect(
        applying,
        lessThan(600),
        reason: 'one pass, not two, and the inbox asked about once',
      );
    });
  });
}
