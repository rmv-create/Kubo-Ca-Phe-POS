import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/menu.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async => shop = await PosFixture.open());
  tearDown(() async => shop.close());

  group('pricing', () {
    test('a plain drink costs its size price', () async {
      final DraftItem item = await shop.item('Spanish Latte', 'Grande');
      expect(item.unitPrice, Money.of(139));
      expect(item.lineTotal, Money.of(139));
    });

    test(
      'the Small price is used for a Small, not a fraction of the Grande',
      () async {
        final DraftItem small = await shop.item('Spanish Latte', 'Small');
        expect(small.unitPrice, Money.of(129));
      },
    );

    test('options add their own charges', () async {
      final DraftItem item = await shop.item(
        'Spanish Latte',
        'Grande',
        options: <DraftOption>[
          await shop.draftOption('milk', 'Oat'), // +20
          await shop.draftOption('syrup', 'Vanilla'), // +30
        ],
      );
      expect(item.unitCustomization, Money.of(50));
      expect(item.unitPrice, Money.of(189));
    });

    test('a free option adds nothing', () async {
      final DraftItem item = await shop.item(
        'Spanish Latte',
        'Grande',
        options: <DraftOption>[await shop.draftOption('milk', 'Full Cream')],
      );
      expect(item.unitPrice, Money.of(139));
    });

    test('quantity multiplies exactly', () async {
      final DraftItem item = await shop.item(
        'Vietnamese Sea Salt Cream',
        'Grande',
        quantity: 3,
      );
      expect(item.lineTotal, Money.of(477));
    });

    test('the order total is the sum of its lines', () async {
      final OrderDraft draft = OrderDraft(
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Grande', lineId: 'a'),
          await shop.item(
            'Vietnamese Sea Salt Cream',
            'Grande',
            quantity: 2,
            lineId: 'b',
          ),
          await shop.item(
            'Matcha Oat Latte',
            'Grande',
            lineId: 'c',
            options: <DraftOption>[
              await shop.draftOption('extras', 'Sea Salt Cream'),
            ],
          ),
        ],
      );
      // Grande Spanish Latte 139, two Sea Salt Creams at 159, and a Grande
      // Matcha Oat Latte 149 with ₱20 of sea salt cream on it.
      expect(draft.subtotal, Money.of(626));
      expect(draft.drinkCount, 4);
    });
  });

  group('what stops an order completing', () {
    test('an empty order cannot be completed', () async {
      const OrderDraft draft = OrderDraft(paymentMethod: PaymentMethod.cash);
      expect(draft.whyNotComplete(), 'Add a drink first.');
      await expectLater(
        shop.sell(draft),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('an order with no payment method cannot be completed', () async {
      final OrderDraft draft = OrderDraft(
        items: <DraftItem>[await shop.item('Black', 'Grande')],
      );
      // The methods are the owner's to configure now, so the prompt no
      // longer names two of them.
      expect(draft.whyNotComplete(), 'Choose how it was paid.');
      await expectLater(
        shop.sell(draft),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('GCash cannot be completed until the money is confirmed', () async {
      final OrderDraft draft = OrderDraft(
        items: <DraftItem>[await shop.item('Black', 'Grande')],
        paymentMethod: PaymentMethod.gcash,
      );
      expect(draft.canComplete, isFalse);
      expect(draft.whyNotComplete(), 'Confirm the GCash payment arrived.');
      await expectLater(
        shop.sell(draft),
        throwsA(
          isA<BusinessRuleException>().having(
            (BusinessRuleException e) => e.message,
            'message',
            contains('GCash'),
          ),
        ),
      );
      expect(await shop.countOf('orders'), 0, reason: 'nothing was written');
      expect(await shop.countOf('payments'), 0);
    });

    test('GCash completes once confirmed', () async {
      final OrderDraft draft = OrderDraft(
        items: <DraftItem>[await shop.item('Black', 'Grande')],
        paymentMethod: PaymentMethod.gcash,
        paymentConfirmed: true,
        paymentReference: 'REF123',
      );
      final CompletedOrder order = await shop.sell(draft);
      expect(order.paymentMethod, PaymentMethod.gcash);

      final List<Map<String, Object?>> payment = await shop.db.db.query(
        'payments',
      );
      expect(payment.single['status'], 'confirmed');
      expect(payment.single['reference_no'], 'REF123');
      expect(payment.single['confirmed_at'], isNotNull);
    });

    test('cash is settled the moment it is taken', () async {
      final OrderDraft draft = OrderDraft(
        items: <DraftItem>[await shop.item('Black', 'Grande')],
        paymentMethod: PaymentMethod.cash,
        tendered: Money.of(200),
      );
      await shop.sell(draft);
      final Map<String, Object?> payment = (await shop.db.db.query(
        'payments',
      )).single;
      expect(payment['status'], 'confirmed');
      expect(payment['tendered_centavos'], 20000);
      expect(payment['change_centavos'], 6100);
    });
  });

  group('what a completed order records', () {
    test('the sale, its lines and its options, in one go', () async {
      final OrderDraft draft = OrderDraft(
        items: <DraftItem>[
          await shop.item(
            'Spanish Latte',
            'Grande',
            lineId: 'a',
            options: <DraftOption>[
              await shop.draftOption('milk', 'Oat'),
              await shop.draftOption('ice', 'Less Ice'),
            ],
          ),
        ],
        paymentMethod: PaymentMethod.cash,
      );
      final CompletedOrder order = await shop.sell(draft);

      expect(await shop.storedTotal(order.id), Money.of(159));
      expect(await shop.countOf('order_items'), 1);
      expect(await shop.countOf('order_item_customizations'), 2);
      expect(await shop.countOf('payments'), 1);
      expect(await shop.countOf('audit_log'), 1);
    });

    test('snapshots survive the drink being renamed afterwards', () async {
      final OrderDraft draft = OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
        paymentMethod: PaymentMethod.cash,
      );
      await shop.sell(draft);

      final Product product = await shop.product('Spanish Latte');
      await shop.menu.updateProduct(product.copyWith(name: 'Renamed Latte'));

      final Map<String, Object?> item = (await shop.db.db.query(
        'order_items',
      )).single;
      expect(item['product_name_snapshot'], 'Spanish Latte');
      expect(item['size_name_snapshot'], 'Grande');
      expect(item['size_volume_oz_snapshot'], 16.0);
      expect(item['unit_price_centavos'], 13900);
    });

    test('an uncosted sale claims no profit', () async {
      // Recipes arrive in Delivery 4. Until then COGS is genuinely unknown,
      // and a null recipe_version_id is what marks it as such — the app must
      // not report the full price as profit in the meantime.
      final OrderDraft draft = OrderDraft(
        items: <DraftItem>[await shop.item('Black', 'Grande')],
        paymentMethod: PaymentMethod.cash,
      );
      final CompletedOrder order = await shop.sell(draft);

      final Map<String, Object?> row = (await shop.db.db.query(
        'orders',
        where: 'id = ?',
        whereArgs: <Object?>[order.id],
      )).single;
      expect(row['cogs_centavos'], 0);
      expect(row['gross_profit_centavos'], 0);
      expect(
        (await shop.db.db.query('order_items')).single['recipe_version_id'],
        isNull,
      );
    });

    test('an order without a customer is a perfectly good order', () async {
      final OrderDraft draft = OrderDraft(
        items: <DraftItem>[await shop.item('Black', 'Grande')],
        paymentMethod: PaymentMethod.cash,
      );
      final CompletedOrder order = await shop.sell(draft);
      expect(order.customerName, isNull);
      expect(await shop.countOf('customer_order_patterns'), 0);
    });
  });

  group('order numbers', () {
    test('run K-0001 onwards', () async {
      for (int i = 1; i <= 3; i++) {
        final CompletedOrder order = await shop.sell(
          OrderDraft(
            items: <DraftItem>[await shop.item('Black', 'Grande')],
            paymentMethod: PaymentMethod.cash,
          ),
        );
        expect(order.orderNo, 'K-000$i');
      }
    });

    test('do not restart the next day, as the owner asked', () async {
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      shop.clock.advance(const Duration(days: 1));
      final CompletedOrder next = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      expect(next.orderNo, 'K-0002');
    });

    test('carry the day when the counter is set to restart daily', () async {
      // Restarting at 0001 every morning would produce the same number twice,
      // so the date becomes part of it. The owner has this switched off.
      final BusinessSettings daily = shop.settings.copyWith(
        orderNumberResetDaily: true,
      );
      final CompletedOrder first = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
        using: daily,
      );
      expect(first.orderNo, 'K-0315-0001');

      shop.clock.advance(const Duration(days: 1));
      final CompletedOrder next = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
        using: daily,
      );
      expect(next.orderNo, 'K-0316-0001');
      expect(next.orderNo, isNot(first.orderNo));
    });

    test('a sale after midnight belongs to the previous trading day', () async {
      shop.clock.set(DateTime(2026, 3, 16, 0, 30));
      final CompletedOrder order = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      expect(order.businessDate, '2026-03-15');
    });
  });

  group('customer history', () {
    late int mariaId;

    setUp(() async {
      mariaId = await shop.customers.create(
        name: 'Maria Santos',
        mobile: '0917 555 4521',
      );
    });

    test('a completed order updates visits, spend and segment', () async {
      final Customer before = (await shop.customers.byId(mariaId))!;
      expect(before.orderCount, 0);
      expect(before.storedSegment, CustomerSegment.newCustomer);

      await shop.sell(
        OrderDraft(
          customer: before,
          items: <DraftItem>[
            await shop.item('Spanish Latte', 'Grande', quantity: 2),
          ],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      final Customer after = (await shop.customers.byId(mariaId))!;
      expect(after.orderCount, 1);
      expect(after.visitCount, 1);
      expect(after.itemCount, 2);
      expect(after.totalSpend, Money.of(278));
      expect(after.firstVisitAt, isNotNull);
      expect(after.lastVisitAt, isNotNull);
    });

    test('segments move with the order count', () async {
      for (int i = 0; i < 6; i++) {
        final Customer current = (await shop.customers.byId(mariaId))!;
        await shop.sell(
          OrderDraft(
            customer: current,
            items: <DraftItem>[await shop.item('Black', 'Grande')],
            paymentMethod: PaymentMethod.cash,
          ),
        );
      }
      final Customer after = (await shop.customers.byId(mariaId))!;
      expect(after.orderCount, 6);
      expect(after.storedSegment, CustomerSegment.frequent);
    });

    test(
      'a customer who has not been in for a month reads as at risk',
      () async {
        final Customer maria = (await shop.customers.byId(mariaId))!;
        for (int i = 0; i < 2; i++) {
          final Customer current = (await shop.customers.byId(mariaId))!;
          await shop.sell(
            OrderDraft(
              customer: current,
              items: <DraftItem>[await shop.item('Black', 'Grande')],
              paymentMethod: PaymentMethod.cash,
            ),
          );
        }
        final Customer after = (await shop.customers.byId(mariaId))!;
        final DateTime later = shop.clock.now().add(const Duration(days: 45));
        expect(after.segmentAt(shop.clock.now()), CustomerSegment.regular);
        expect(after.segmentAt(later), CustomerSegment.atRisk);
        expect(
          maria.orderCount,
          0,
          reason: 'the original snapshot is immutable',
        );
      },
    );

    test('average order value is the total divided by the orders', () async {
      for (final String size in <String>['Grande', 'Small']) {
        final Customer current = (await shop.customers.byId(mariaId))!;
        await shop.sell(
          OrderDraft(
            customer: current,
            items: <DraftItem>[await shop.item('Spanish Latte', size)],
            paymentMethod: PaymentMethod.cash,
          ),
        );
      }
      final Customer after = (await shop.customers.byId(mariaId))!;
      expect(after.totalSpend, Money.of(268));
      expect(after.averageOrderValue, Money.of(134));
    });
  });
}
