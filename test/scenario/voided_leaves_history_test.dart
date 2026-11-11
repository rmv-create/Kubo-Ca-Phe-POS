import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// A void says the drink was never handed over, so the customer's own
/// history should not go on saying otherwise.
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
    await shop.setRecipe('Spanish Latte', 'Large', <Ingredient, double>{
      beans: 20,
    });
    await shop.setRecipe('Iced Black', 'Large', <Ingredient, double>{
      beans: 20,
    });
    final int id = await shop.customers.create(
      name: 'James',
      mobile: '0917 000 0000',
    );
    james = (await shop.customers.byId(id))!;
  });

  tearDown(() async => shop.close());

  Future<CompletedOrder> sellTo(String drink) async => shop.sell(
    OrderDraft(
      customer: james,
      items: <DraftItem>[await shop.item(drink, 'Large')],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  test('a voided order leaves the history', () async {
    final CompletedOrder kept = await sellTo('Spanish Latte');
    final CompletedOrder undone = await sellTo('Iced Black');

    expect(
      (await shop.sales.orders(
        customerId: james.id,
        includeVoided: false,
      )).length,
      2,
    );

    await shop.sales.voidOrder(orderId: undone.id, reason: 'Rung by mistake');

    final List<OrderRecord> history = await shop.sales.orders(
      customerId: james.id,
      includeVoided: false,
    );
    expect(history.length, 1);
    expect(history.single.id, kept.id);
  });

  test('but the day still shows what was undone', () async {
    final CompletedOrder undone = await sellTo('Iced Black');
    await shop.sales.voidOrder(orderId: undone.id, reason: 'Rung by mistake');

    final List<OrderRecord> day = await shop.sales.orders(
      businessDate: shop.reports.today,
    );
    expect(day.where((OrderRecord o) => o.isVoided).length, 1);
  });

  test('a deleted order is gone from the history too', () async {
    final CompletedOrder bin = await sellTo('Iced Black');
    await shop.sales.deleteOrder(orderId: bin.id, reason: 'Practice');

    expect(
      await shop.sales.orders(customerId: james.id, includeVoided: false),
      isEmpty,
    );
  });

  test('a voided drink never becomes the usual', () async {
    // Ringing the wrong drink up against a regular and voiding it used to
    // teach the app that it was their usual, and "same again" then offered
    // the drink they never had.
    // A usual needs two of the same drink, so two go wrong here.
    await sellTo('Iced Black');
    final CompletedOrder wrong = await sellTo('Iced Black');
    expect(await shop.customers.usualFor(james.id), isNotNull);

    await shop.sales.voidOrder(orderId: wrong.id, reason: 'Wrong drink');

    expect(
      await shop.customers.usualFor(james.id),
      isNull,
      reason: 'one of the two is undone, so it is no longer a habit',
    );
  });

  test('the drinks they really did have stay the usual', () async {
    await sellTo('Spanish Latte');
    await sellTo('Spanish Latte');
    final CompletedOrder wrong = await sellTo('Iced Black');

    await shop.sales.voidOrder(orderId: wrong.id, reason: 'Wrong drink');

    final UsualOrder? usual = await shop.customers.usualFor(james.id);
    expect(usual, isNotNull);
    expect(usual!.productName, 'Spanish Latte');
  });

  test('their counts come back down as well', () async {
    await sellTo('Spanish Latte');
    final CompletedOrder wrong = await sellTo('Iced Black');

    await shop.sales.voidOrder(orderId: wrong.id, reason: 'Wrong drink');

    final Customer after = (await shop.customers.byId(james.id))!;
    expect(after.orderCount, 1);
  });
}
