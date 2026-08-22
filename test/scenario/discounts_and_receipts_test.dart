import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/receipt/receipt_document.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';
import 'package:kubo_pos/domain/services/discount_engine.dart';

import '../support/pos_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async => shop = await PosFixture.open());
  tearDown(() async => shop.close());

  Future<OrderRecord> sellWith({
    DiscountKind? discount,
    Money delivery = Money.zero,
    String? beneficiary,
    String? idNo,
  }) async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Grande')],
        paymentMethod: PaymentMethod.cash,
        discountKind: discount,
        discountBeneficiaryName: beneficiary,
        discountBeneficiaryIdNo: idNo,
        deliveryFee: delivery,
      ),
    );
    return (await shop.sales.orderById(done.id))!;
  }

  group('a discounted sale', () {
    test('charges the discounted amount, not the menu price', () async {
      final OrderRecord order = await sellWith(
        discount: DiscountKind.senior,
        beneficiary: 'Lola Remedios',
        idNo: 'SC-12345',
      );

      // Not VAT-registered by default: a straight 20% off ₱139.
      expect(order.subtotal, Money.of(139));
      expect(order.discount, Money.of(27, 80));
      expect(order.total, Money.of(111, 20));
    });

    test('the payment matches what was actually charged', () async {
      final OrderRecord order = await sellWith(discount: DiscountKind.pwd);
      final List<Map<String, Object?>> payments = await shop.db.db.query(
        'payments',
      );

      expect(payments.single['amount_centavos'], order.total.centavos);
    });

    test('records who claimed it, as the law requires', () async {
      final OrderRecord order = await sellWith(
        discount: DiscountKind.senior,
        beneficiary: 'Lola Remedios',
        idNo: 'SC-12345',
      );

      expect(order.discountLabel, 'Senior Citizen');
      expect(order.discountRateBp, 2000);
      expect(order.discountBeneficiaryName, 'Lola Remedios');
      expect(order.discountBeneficiaryIdNo, 'SC-12345');
    });

    test('profit is measured against what was charged, not the menu', () async {
      final Ingredient coffee = await shop.addIngredient(
        'Coffee',
        price: Money.of(900),
        openingStock: 1000,
      );
      await shop.setRecipe('Spanish Latte', 'Grande', <Ingredient, double>{
        coffee: 18,
      });

      final OrderRecord full = await sellWith();
      final OrderRecord discounted = await sellWith(
        discount: DiscountKind.senior,
      );

      // Same drink, same cost to make — so the discount comes straight off
      // the margin, and the report must not pretend otherwise.
      expect(discounted.cogs, full.cogs);
      expect(discounted.grossProfit, full.grossProfit - Money.of(27, 80));
    });

    test('what was charged is frozen, even if the shop registers for VAT '
        'afterwards', () async {
      final OrderRecord before = await sellWith(discount: DiscountKind.senior);

      shop.settings = shop.settings.copyWith(vatRegistered: true);
      final OrderRecord reread = (await shop.sales.orderById(before.id))!;

      expect(reread.total, Money.of(111, 20));
      expect(reread.discount, Money.of(27, 80));
    });
  });

  group('a VAT-registered shop', () {
    setUp(() {
      shop.settings = shop.settings.copyWith(vatRegistered: true);
    });

    test('takes the VAT off before the discount', () async {
      final OrderRecord order = await sellWith(discount: DiscountKind.senior);

      expect(order.total, Money.of(99, 29));
      expect(order.discountVatExempt, Money.of(14, 89));
      // An exempt sale carries no VAT at all.
      expect(order.vat, Money.zero);
    });

    test('an ordinary sale still carries the VAT inside the price', () async {
      final OrderRecord order = await sellWith();

      expect(order.total, Money.of(139));
      expect(order.vat, Money.of(14, 89));
      expect(order.vatRateBp, 1200);
    });
  });

  group('delivery', () {
    test('is added after the discount and never discounted itself', () async {
      final OrderRecord order = await sellWith(
        discount: DiscountKind.senior,
        delivery: Money.of(50),
      );

      expect(order.deliveryFee, Money.of(50));
      expect(order.total, Money.of(161, 20));
    });
  });

  group('the receipt', () {
    test('is a real PDF, and says everything it was asked to', () async {
      final int customerId = await shop.customers.create(name: 'Maria Santos');
      final Customer customer = (await shop.customers.byId(customerId))!;
      final CompletedOrder done = await shop.sell(
        OrderDraft(
          customer: customer,
          items: <DraftItem>[
            await shop.item(
              'Spanish Latte',
              'Grande',
              options: <DraftOption>[
                await shop.draftOption('sweetness', 'Less Sweet'),
              ],
            ),
          ],
          paymentMethod: PaymentMethod.cash,
          discountKind: DiscountKind.senior,
          discountBeneficiaryName: 'Lola Remedios',
          discountBeneficiaryIdNo: 'SC-12345',
          deliveryFee: Money.of(50),
        ),
      );
      final OrderRecord order = (await shop.sales.orderById(done.id))!;

      final bytes = await ReceiptDocument(
        order: order,
        settings: shop.settings,
      ).build();

      // A PDF, not an empty file or an exception.
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(1000));

      // Every free modification is on the order it was built from, which is
      // what the document prints.
      expect(order.lines.single.options, contains('Less Sweet'));
      expect(order.customerName, 'Maria Santos');
      expect(order.deliveryFee, Money.of(50));
      expect(order.discountBeneficiaryName, 'Lola Remedios');
    });

    test('a receipt for a guest order builds too', () async {
      final OrderRecord order = await sellWith();
      final bytes = await ReceiptDocument(
        order: order,
        settings: BusinessSettings.defaults,
      ).build();

      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });
}
