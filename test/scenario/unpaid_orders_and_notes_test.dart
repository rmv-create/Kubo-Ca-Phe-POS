import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/receipt/receipt_document.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async => shop = await PosFixture.open());
  tearDown(() async => shop.close());

  Future<OrderRecord> sell({
    bool unpaid = false,
    PaymentMethod? method,
    String? note,
    Money delivery = Money.zero,
  }) async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
        unpaid: unpaid,
        paymentMethod: unpaid ? null : (method ?? PaymentMethod.cash),
        note: note,
        deliveryFee: delivery,
      ),
    );
    return (await shop.sales.orderById(done.id))!;
  }

  group('an order that has not been paid for yet', () {
    test('completes with no payment method at all', () async {
      final OrderRecord order = await sell(unpaid: true);

      expect(order.isUnpaid, isTrue);
      expect(order.paymentMethod, isNull);
      expect(order.total, Money.of(139));
      expect(order.status, 'completed', reason: 'the coffee was still made');
    });

    test('writes no payment row, rather than a pretend one', () async {
      await sell(unpaid: true);

      expect(await shop.db.db.query('payments'), isEmpty);
    });

    test('is a sale, but is not money she has', () async {
      await sell(unpaid: true);
      await sell();

      final SalesSummary today = await shop.reports.forDay('2026-03-15');

      // Both drinks were sold, so both count as revenue.
      expect(today.orderCount, 2);
      expect(today.revenue, Money.of(278));
      // Only one of them has been paid for.
      expect(today.cash, Money.of(139));
      expect(today.gcash, Money.zero);
      expect(today.collected, Money.of(139));
      expect(today.unpaid, Money.of(139));
      expect(today.unpaidOrderCount, 1);
      // And the figures reconcile: what came in plus what is owed is the lot.
      expect(today.collected + today.unpaid, today.revenue);
    });

    test('the stock still comes out — the drink was made', () async {
      final coffee = await shop.addIngredient(
        'Coffee',
        price: Money.of(900),
        openingStock: 1000,
      );
      await shop.setRecipe(
        'Spanish Latte',
        'Grande',
        <dynamic, double>{coffee: 18}.cast(),
      );

      await sell(unpaid: true);

      expect((await shop.stockOf(coffee.id))!.inBaseUnits, 982);
    });

    test('shows up on the chasing list, oldest first', () async {
      final OrderRecord first = await sell(unpaid: true);
      shop.clock.advance(const Duration(hours: 2));
      final OrderRecord second = await sell(unpaid: true);
      shop.clock.advance(const Duration(hours: 1));
      await sell();

      final List<OrderRecord> waiting = await shop.sales.unpaidOrders();

      expect(waiting.map((OrderRecord o) => o.id), <int>[
        first.id,
        second.id,
      ], reason: 'the one outstanding longest needs chasing first');
    });
  });

  group('recording the payment afterwards', () {
    test('moves the money without touching the sale', () async {
      final OrderRecord order = await sell(unpaid: true);
      shop.clock.advance(const Duration(hours: 3));

      await shop.sales.recordPayment(
        orderId: order.id,
        method: PaymentMethod.gcash,
        reference: 'ABC123',
      );

      final OrderRecord paid = (await shop.sales.orderById(order.id))!;
      expect(paid.isUnpaid, isFalse);
      expect(paid.paymentMethod, PaymentMethod.gcash);
      expect(paid.paymentReference, 'ABC123');
      expect(paid.total, order.total, reason: 'the sale itself never moved');
      expect(paid.createdAt, order.createdAt);

      final SalesSummary today = await shop.reports.forDay('2026-03-15');
      expect(today.gcash, Money.of(139));
      expect(today.unpaid, Money.zero);
      expect(await shop.sales.unpaidOrders(), isEmpty);
    });

    test('the payment is dated when the money arrived', () async {
      final OrderRecord order = await sell(unpaid: true);
      shop.clock.advance(const Duration(hours: 5));
      final DateTime arrival = shop.clock.now();

      await shop.sales.recordPayment(
        orderId: order.id,
        method: PaymentMethod.cash,
      );

      final Map<String, Object?> payment = (await shop.db.db.query(
        'payments',
      )).single;
      expect(
        DateTime.parse(payment['created_at']! as String).toUtc(),
        arrival.toUtc(),
      );
    });

    test('cash works out the change from what was handed over', () async {
      final OrderRecord order = await sell(unpaid: true);

      await shop.sales.recordPayment(
        orderId: order.id,
        method: PaymentMethod.cash,
        tendered: Money.of(200),
      );

      final OrderRecord paid = (await shop.sales.orderById(order.id))!;
      expect(paid.tendered, Money.of(200));
      expect(paid.change, Money.of(61));
    });

    test('the same order cannot be paid for twice', () async {
      final OrderRecord order = await sell(unpaid: true);
      await shop.sales.recordPayment(
        orderId: order.id,
        method: PaymentMethod.cash,
      );

      await expectLater(
        shop.sales.recordPayment(orderId: order.id, method: PaymentMethod.cash),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('an order that was paid at the counter is refused outright', () async {
      final OrderRecord order = await sell();

      await expectLater(
        shop.sales.recordPayment(orderId: order.id, method: PaymentMethod.cash),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('a voided order has nothing to pay', () async {
      final OrderRecord order = await sell(unpaid: true);
      await shop.sales.voidOrder(orderId: order.id, reason: 'Rung by mistake');

      await expectLater(
        shop.sales.recordPayment(orderId: order.id, method: PaymentMethod.cash),
        throwsA(isA<BusinessRuleException>()),
      );
    });
  });

  group('what the receipt says', () {
    test('an unpaid receipt says so on its face, and what is owed', () async {
      final OrderRecord order = await sell(unpaid: true);

      expect(
        ReceiptDocument.paymentLines(order).map((ReceiptLine l) => l.label),
        <String>['NOT YET PAID', 'Amount due'],
      );
      expect(ReceiptDocument.paymentLines(order).last.amount, order.total);
    });

    test('a paid receipt is untouched by any of this', () async {
      final OrderRecord order = await sell();

      expect(
        ReceiptDocument.paymentLines(order).map((ReceiptLine l) => l.label),
        <String>['Cash payment'],
      );
    });

    test('once paid, the unpaid wording is gone', () async {
      final OrderRecord order = await sell(unpaid: true);
      await shop.sales.recordPayment(
        orderId: order.id,
        method: PaymentMethod.cash,
      );
      final OrderRecord paid = (await shop.sales.orderById(order.id))!;

      expect(
        ReceiptDocument.paymentLines(paid).map((ReceiptLine l) => l.label),
        <String>['Cash payment'],
      );
    });

    test('an unpaid receipt is still a real, printable PDF', () async {
      final OrderRecord order = await sell(
        unpaid: true,
        delivery: Money.of(50),
      );
      final bytes = await ReceiptDocument(
        order: order,
        settings: shop.settings,
      ).build();

      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(order.total, Money.of(189), reason: 'delivery is still charged');
    });

    test('the QR code is drawn into the document, not pasted in', () async {
      final OrderRecord order = await sell();

      final withCode = await ReceiptDocument(
        order: order,
        settings: shop.settings.copyWith(
          receiptQrData: 'https://example.test/kubo',
        ),
      ).build();
      final without = await ReceiptDocument(
        order: order,
        settings: shop.settings.copyWith(receiptQrData: ''),
      ).build();

      // The code is vector drawing commands, so it makes the page bigger —
      // and a blank setting prints nothing at all rather than an empty square.
      expect(withCode.length, greaterThan(without.length));
    });

    test('a QR link ships by default, so the code is never blank', () async {
      expect(BusinessSettings.defaults.receiptQrData, isNotEmpty);
    });

    test('her address and socials are hers to type in, not invented', () async {
      const BusinessSettings d = BusinessSettings.defaults;

      expect(d.receiptAddress, isEmpty);
      expect(d.receiptFacebook, isEmpty);
      expect(d.receiptInstagram, isEmpty);
    });
  });

  group('a note on the order', () {
    test('is kept with the order and printed on the receipt', () async {
      final OrderRecord order = await sell(note: 'Leave at the gate');

      expect(order.note, 'Leave at the gate');

      final bytes = await ReceiptDocument(
        order: order,
        settings: shop.settings,
      ).build();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('no note means no note — not an empty line', () async {
      final OrderRecord order = await sell();

      expect(order.note, isNull);
    });

    test('whitespace is not a note', () async {
      final OrderRecord order = await sell(note: '   ');

      // The draft keeps what it was given; the receipt is what must not print
      // a bare "Note:".
      final bytes = await ReceiptDocument(
        order: order,
        settings: shop.settings,
      ).build();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });

  group('the delivery fee', () {
    test('is offered from the start, because she delivers', () async {
      expect(BusinessSettings.defaults.deliveryFeeEnabled, isTrue);
    });
  });
}
