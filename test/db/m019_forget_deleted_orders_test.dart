import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/db/migrations/m019_forget_deleted_orders.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';

/// Orders deleted before voiding learned to forget them left the drink
/// behind as somebody's usual.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late Customer james;

  setUp(() async {
    shop = await PosFixture.open();
    final Ingredient beans = await shop.addIngredient(
      'Coffee beans',
      price: Money.of(1200),
      openingStock: 5000,
    );
    await shop.setRecipe('Iced Black', 'Large', <Ingredient, double>{
      beans: 20,
    });
    await shop.setRecipe('Spanish Latte', 'Large', <Ingredient, double>{
      beans: 20,
    });
    final int id = await shop.customers.create(name: 'James');
    james = (await shop.customers.byId(id))!;
  });

  tearDown(() async => shop.close());

  Future<CompletedOrder> sell(String drink) async => shop.sell(
    OrderDraft(
      customer: james,
      items: <DraftItem>[await shop.item(drink, 'Large')],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  Future<int> patterns() async =>
      (await shop.db.db.query('customer_order_patterns')).length;

  test('a habit left behind by a deleted order is forgotten', () async {
    final CompletedOrder a = await sell('Iced Black');
    final CompletedOrder b = await sell('Iced Black');
    expect(await shop.customers.usualFor(james.id), isNotNull);

    // The old behaviour: the orders go, the habit stays.
    for (final CompletedOrder o in <CompletedOrder>[a, b]) {
      await shop.db.db.delete(
        'orders',
        where: 'id = ?',
        whereArgs: <Object?>[o.id],
      );
    }
    expect(await patterns(), 1, reason: 'this is the state she is in');

    await const M019ForgetDeletedOrders().up(shop.db.db);

    expect(await patterns(), 0);
    expect(await shop.customers.usualFor(james.id), isNull);
  });

  test('the drinks he really did have are left alone', () async {
    await sell('Spanish Latte');
    await sell('Spanish Latte');
    final CompletedOrder gone = await sell('Iced Black');
    await shop.db.db.delete(
      'orders',
      where: 'id = ?',
      whereArgs: <Object?>[gone.id],
    );

    await const M019ForgetDeletedOrders().up(shop.db.db);

    final UsualOrder? usual = await shop.customers.usualFor(james.id);
    expect(usual, isNotNull);
    expect(usual!.productName, 'Spanish Latte');
  });

  test('a count that is merely too high is brought down', () async {
    await sell('Spanish Latte');
    await sell('Spanish Latte');
    final CompletedOrder gone = await sell('Spanish Latte');
    await shop.db.db.delete(
      'orders',
      where: 'id = ?',
      whereArgs: <Object?>[gone.id],
    );

    await const M019ForgetDeletedOrders().up(shop.db.db);

    final List<Map<String, Object?>> rows = await shop.db.db.query(
      'customer_order_patterns',
    );
    expect(rows.single['occurrence_count'], 2);
  });

  test('a voided order does not count towards the habit either', () async {
    await sell('Iced Black');
    final CompletedOrder undone = await sell('Iced Black');
    await shop.db.db.update(
      'orders',
      <String, Object?>{'status': 'voided'},
      where: 'id = ?',
      whereArgs: <Object?>[undone.id],
    );

    await const M019ForgetDeletedOrders().up(shop.db.db);

    final List<Map<String, Object?>> rows = await shop.db.db.query(
      'customer_order_patterns',
    );
    expect(rows.single['occurrence_count'], 1);
  });

  test('running it on a tidy shop changes nothing', () async {
    await sell('Spanish Latte');
    await sell('Spanish Latte');
    final int before = await patterns();

    await const M019ForgetDeletedOrders().up(shop.db.db);

    expect(await patterns(), before);
    expect(await shop.customers.usualFor(james.id), isNotNull);
  });
}
