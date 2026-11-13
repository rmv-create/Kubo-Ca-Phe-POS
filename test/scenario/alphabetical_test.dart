import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/recipe.dart';

import '../support/pos_fixture.dart';

/// Lists she reads by name should be in name order.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
  });
  tearDown(() async => shop.close());

  List<String> sortedCopy(List<String> names) => <String>[...names]
    ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));

  test('ingredients come back A to Z, not grouped by category', () async {
    final List<String> names = (await shop.stock.ingredients())
        .map((Ingredient i) => i.name)
        .toList();

    expect(names, sortedCopy(names));
    expect(names.first, 'Alaska Evaporada');
  });

  test('recipes come back by drink name, not menu order', () async {
    final List<String> drinks = (await shop.recipeBook.recipes())
        .map((Recipe r) => r.productName)
        .toList();

    expect(drinks, sortedCopy(drinks));
    expect(drinks.first, 'Ca Phe Muoi');
  });

  test('the customers page lists everybody A to Z', () async {
    // Added out of order, and with different last visits, so that recency
    // and insertion order would both give something else.
    for (final String name in <String>['Tita Baby', 'Ana', 'james', 'Bea']) {
      await shop.customers.create(name: name);
    }

    final List<String> listed = (await shop.customers.search(
      '',
      alphabetical: true,
    )).map((Customer c) => c.name).toList();

    expect(listed, <String>['Ana', 'Bea', 'james', 'Tita Baby']);
  });

  test('the till still offers whoever came in most recently', () async {
    await shop.customers.create(name: 'Ana');
    final int bea = await shop.customers.create(name: 'Bea');

    await shop.sell(
      OrderDraft(
        customer: (await shop.customers.byId(bea))!,
        items: <DraftItem>[await shop.item('Iced Black', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    // At the counter the question is who is standing there, and the answer
    // is usually somebody who was in recently.
    final List<Customer> atTheTill = await shop.customers.search('');
    expect(atTheTill.first.name, 'Bea');
  });

  test('searching by name is still name-ordered', () async {
    for (final String name in <String>['Jamie', 'James', 'Jam']) {
      await shop.customers.create(name: name);
    }

    final List<String> found = (await shop.customers.search(
      'Jam',
      alphabetical: true,
    )).map((Customer c) => c.name).toList();

    expect(found, <String>['Jam', 'James', 'Jamie']);
  });
}
