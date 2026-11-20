import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';

/// What a customer orders, said in words.
///
/// The screen printed the raw row numbers — "Drink #4, size #2" — which is
/// what the table holds and no use to somebody trying to remember what a
/// regular drinks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late Customer tita;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
    final int id = await shop.customers.create(name: 'Tita Baby');
    tita = (await shop.customers.byId(id))!;
  });
  tearDown(() async => shop.close());

  Future<void> buy(
    String drink,
    String size, {
    List<DraftOption> options = const <DraftOption>[],
  }) async => shop.sell(
    OrderDraft(
      customer: tita,
      items: <DraftItem>[await shop.item(drink, size, options: options)],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  test('the drink and the size are named', () async {
    await buy('Spanish Latte', 'Large');

    final UsualOrder one = (await shop.customers.favouritesFor(tita.id)).single;
    expect(one.title, 'Large Spanish Latte');
    expect(one.pattern.occurrenceCount, 1);
  });

  test('what was in it is named too', () async {
    await buy(
      'Spanish Latte',
      'Large',
      options: <DraftOption>[
        await shop.draftOption('extras', 'Sea Salt Cold Foam'),
      ],
    );

    final UsualOrder one = (await shop.customers.favouritesFor(tita.id)).single;
    expect(one.subtitle, contains('Sea Salt Cold Foam'));
  });

  test('the most often ordered comes first', () async {
    await buy('Iced Black', 'Small');
    await buy('Spanish Latte', 'Large');
    await buy('Spanish Latte', 'Large');

    final List<UsualOrder> all = await shop.customers.favouritesFor(tita.id);
    expect(all.first.title, 'Large Spanish Latte');
    expect(all.first.pattern.occurrenceCount, 2);
    expect(all.last.title, 'Small Iced Black');
  });

  test('each size is its own habit', () async {
    await buy('Spanish Latte', 'Large');
    await buy('Spanish Latte', 'Small');

    final List<UsualOrder> all = await shop.customers.favouritesFor(tita.id);
    expect(all.map((UsualOrder u) => u.title).toSet(), <String>{
      'Large Spanish Latte',
      'Small Spanish Latte',
    });
  });

  test(
    'a drink taken off the menu is left out, not printed as a number',
    () async {
      await buy('Spanish Latte', 'Large');
      await shop.db.db.delete('products', where: "name = 'Spanish Latte'");

      expect(await shop.customers.favouritesFor(tita.id), isEmpty);
    },
  );

  test('somebody who has bought nothing has no habits', () async {
    expect(await shop.customers.favouritesFor(tita.id), isEmpty);
  });
}
