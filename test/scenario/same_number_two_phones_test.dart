import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// Two phones that both reached for the same order number.
///
/// Both were signed in as the owner and serving apart, so each counted
/// from what it could see and both landed on 1165. When they synced, the
/// two sales were treated as one: the customer showed two orders, and the
/// order numbered 1165 held the drinks of both — an order that said two
/// drinks and listed three.
///
/// Two sales are never the same sale, whatever number they carry.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture iphone;
  late PosFixture android;
  late SyncEngine iphoneSync;
  late SyncEngine androidSync;

  setUp(() async {
    iphone = await PosFixture.open(separate: true);
    android = await PosFixture.open(separate: true);
    await PantrySeeder(iphone.db, iphone.clock).seedIfEmpty();
    await PantrySeeder(android.db, android.clock).seedIfEmpty();
    iphoneSync = SyncEngine(database: iphone.db, clock: iphone.clock);
    androidSync = SyncEngine(database: android.db, clock: android.clock);

    // Both counting from the same place, as two owner phones apart do.
    for (final PosFixture shop in <PosFixture>[iphone, android]) {
      shop.settings = shop.settings.copyWith(orderNumberStart: 1165);
    }
  });

  tearDown(() async {
    await iphone.close();
    await android.close();
  });

  Future<CompletedOrder> sell(
    PosFixture shop, {
    Customer? who,
    int drinks = 1,
  }) async => shop.sell(
    OrderDraft(
      customer: who,
      items: <DraftItem>[
        await shop.item('Iced Black', 'Large', quantity: drinks),
      ],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  test('both really do reach for the same number', () async {
    expect((await sell(iphone)).orderNo, 'KUBO-1165');
    expect((await sell(android)).orderNo, 'KUBO-1165');
  });

  test('both sales survive the sync', () async {
    await sell(iphone);
    await sell(android, drinks: 2);

    await iphoneSync.apply(await androidSync.collect());

    final List<OrderRecord> there = await iphone.sales.orders();
    expect(there.length, 2, reason: 'two sales happened, so two are kept');
  });

  test('neither order ends up holding the other one\'s drinks', () async {
    await sell(iphone);
    await sell(android, drinks: 2);

    await iphoneSync.apply(await androidSync.collect());

    for (final OrderRecord order in await iphone.sales.orders()) {
      final int listed = order.lines.fold(
        0,
        (int sum, OrderLineRecord l) => sum + l.quantity,
      );
      expect(
        listed,
        order.itemCount,
        reason: 'the count and the list of drinks must agree',
      );
    }
  });

  test('the one rung up first keeps the number it printed', () async {
    final CompletedOrder first = await sell(iphone);
    android.clock.advance(const Duration(minutes: 5));
    await sell(android);

    await iphoneSync.apply(await androidSync.collect());

    final List<String> numbers = (await iphone.sales.orders())
        .map((OrderRecord o) => o.orderNo)
        .toList();
    expect(numbers, contains(first.orderNo));
    expect(
      numbers.where((String n) => n == first.orderNo).length,
      1,
      reason: 'and only one order carries it',
    );
  });

  test('both phones end up calling them the same two things', () async {
    await sell(iphone);
    android.clock.advance(const Duration(minutes: 5));
    await sell(android);

    final List<SyncChange> fromAndroid = await androidSync.collect();
    final List<SyncChange> fromIphone = await iphoneSync.collect();
    await iphoneSync.apply(fromAndroid);
    await androidSync.apply(fromIphone);

    final List<String> onIphone =
        (await iphone.sales.orders()).map((OrderRecord o) => o.orderNo).toList()
          ..sort();
    final List<String> onAndroid =
        (await android.sales.orders())
            .map((OrderRecord o) => o.orderNo)
            .toList()
          ..sort();

    expect(onIphone, onAndroid, reason: 'no disagreement between the phones');
    expect(onIphone.length, 2);
  });

  test('a customer who bought once is not credited with two', () async {
    final int id = await iphone.customers.create(name: 'Tita Baby');
    final Customer who = (await iphone.customers.byId(id))!;
    await sell(iphone, who: who);

    // The other phone sells to nobody; only its own order travels.
    await sell(android, drinks: 2);
    await iphoneSync.apply(await androidSync.collect());

    expect((await iphone.customers.byId(id))!.orderCount, 1);
    expect(
      (await iphone.sales.orders(customerId: id)).length,
      1,
      reason: 'her one order, not the other phone\'s as well',
    );
  });
}
