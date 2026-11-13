import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// The note is hers: it tells two people with the same name apart at the
/// counter, and the customer never sees it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

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
  });

  tearDown(() async => shop.close());

  test('a note can be given while the order is being taken', () async {
    // What the till's "new customer" box now asks for, so that a second
    // James can be saved at the counter rather than refused there.
    final int id = await shop.customers.create(
      name: 'James',
      mobile: '0917 000 0000',
      notes: 'Office',
    );

    expect((await shop.customers.byId(id))!.notes, 'Office');
  });

  test('two Jameses can both be added at the till', () async {
    await shop.customers.create(name: 'James', notes: 'Office');
    await shop.customers.create(name: 'James', notes: 'Classmate');

    final List<Customer> both = await shop.customers.search('James');
    expect(both.length, 2);
    expect(both.map((Customer c) => c.notes).toSet(), <String>{
      'Office',
      'Classmate',
    });
  });

  test('the note never reaches the receipt', () async {
    final int id = await shop.customers.create(name: 'James', notes: 'Brother');
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        customer: (await shop.customers.byId(id))!,
        items: <DraftItem>[await shop.item('Iced Black', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    final OrderRecord order = (await shop.sales.orderById(done.id))!;
    // The receipt is built from the order, and the order carries the name
    // the drink was sold under and nothing she wrote about the person.
    expect(order.customerName, 'James');
    expect(
      order.toString().contains('Brother'),
      isFalse,
      reason: 'nothing on the order carries her note',
    );
  });
}
