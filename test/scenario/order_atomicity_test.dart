import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/menu.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';

/// Completing an order writes to seven tables. Either all of it lands or none
/// of it does — a payment without a sale, or stock movement without revenue,
/// would quietly corrupt the books.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async => shop = await PosFixture.open());
  tearDown(() async => shop.close());

  Future<Map<String, int>> counts() async => <String, int>{
    'orders': await shop.countOf('orders'),
    'order_items': await shop.countOf('order_items'),
    'order_item_customizations': await shop.countOf(
      'order_item_customizations',
    ),
    'payments': await shop.countOf('payments'),
    'customer_order_patterns': await shop.countOf('customer_order_patterns'),
    'audit_log': await shop.countOf('audit_log'),
  };

  test('a failure mid-commit leaves nothing behind', () async {
    final int mariaId = await shop.customers.create(name: 'Maria Santos');
    final Customer maria = (await shop.customers.byId(mariaId))!;

    // A good first order, so there is something to be corrupted.
    await shop.sell(
      OrderDraft(
        customer: maria,
        items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    final Map<String, int> before = await counts();

    // Now an order whose second line points at a product that has been
    // deleted from under it: the first line inserts, the second violates the
    // foreign key, and the whole unit must roll back.
    final Product ghost = Product(
      id: 999999,
      categoryId: 1,
      name: 'Deleted Drink',
      description: null,
      displayOrder: 0,
      isActive: true,
      isArchived: false,
      sizes: (await shop.product('Black')).sizes,
    );
    final Customer refreshed = (await shop.customers.byId(mariaId))!;

    await expectLater(
      shop.sell(
        OrderDraft(
          customer: refreshed,
          items: <DraftItem>[
            await shop.item('Black', 'Grande', lineId: 'good'),
            DraftItem(
              lineId: 'bad',
              product: ghost,
              size: (await shop.product('Black')).sizes.first,
              quantity: 1,
              options: const <DraftOption>[],
            ),
          ],
          paymentMethod: PaymentMethod.cash,
        ),
      ),
      throwsA(anything),
    );

    expect(
      await counts(),
      before,
      reason: 'not one row of the failed order may survive',
    );

    final Customer after = (await shop.customers.byId(mariaId))!;
    expect(
      after.orderCount,
      refreshed.orderCount,
      reason: 'the customer must not be credited with an order that failed',
    );
    expect(after.totalSpend, refreshed.totalSpend);
  });

  test('a rejected order never reaches the database at all', () async {
    final Map<String, int> before = await counts();
    await expectLater(
      shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.gcash,
          // Not confirmed.
        ),
      ),
      throwsA(anything),
    );
    expect(await counts(), before);
  });

  test(
    'completing twice writes two separate orders, not one doubled',
    () async {
      for (int i = 0; i < 2; i++) {
        await shop.sell(
          OrderDraft(
            items: <DraftItem>[await shop.item('Black', 'Grande')],
            paymentMethod: PaymentMethod.cash,
          ),
        );
      }
      expect(await shop.countOf('orders'), 2);
      expect(await shop.countOf('payments'), 2);

      final List<Map<String, Object?>> orders = await shop.db.db.query(
        'orders',
        columns: <String>['order_no'],
      );
      expect(
        orders.map((Map<String, Object?> r) => r['order_no']).toSet().length,
        2,
        reason: 'order numbers must be unique',
      );
    },
  );

  test('the payment always matches the order total', () async {
    final CompletedOrder order = await shop.sell(
      OrderDraft(
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Grande', lineId: 'a'),
          await shop.item(
            'Matcha Latte',
            'Small',
            lineId: 'b',
            options: <DraftOption>[
              await shop.draftOption('extras', 'Sea Salt Cream'),
            ],
          ),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    final Money stored = await shop.storedTotal(order.id);
    final Map<String, Object?> payment = (await shop.db.db.query(
      'payments',
    )).single;
    expect(payment['amount_centavos'], stored.centavos);
    // 139 + (129 + 20)
    expect(stored, Money.of(288));
  });

  test('the line totals add up to the order total', () async {
    final CompletedOrder order = await shop.sell(
      OrderDraft(
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Grande', quantity: 2, lineId: 'a'),
          await shop.item('Black', 'Small', lineId: 'b'),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    final List<Map<String, Object?>> lines = await shop.db.db.query(
      'order_items',
      columns: <String>['line_total_centavos'],
      where: 'order_id = ?',
      whereArgs: <Object?>[order.id],
    );
    final int sum = lines.fold(
      0,
      (int total, Map<String, Object?> r) =>
          total + (r['line_total_centavos']! as int),
    );
    expect(Money(sum), await shop.storedTotal(order.id));
  });

  test('every completed order leaves an audit entry', () async {
    final CompletedOrder order = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Black', 'Grande')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    final Map<String, Object?> entry = (await shop.db.db.query(
      'audit_log',
    )).single;
    expect(entry['action'], 'order_completed');
    expect(entry['entity_id'], order.id);
    expect(entry['summary'], contains(order.orderNo));
    expect(entry['business_date'], order.businessDate);
  });
}
