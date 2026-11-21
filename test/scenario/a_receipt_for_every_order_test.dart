import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/data/receipt/receipt_document.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// A receipt still comes out for every order she can reach.
///
/// She could not generate one, so this walks the orders my recent changes
/// touch — corrected, moved to another day, unpaid, voided — and builds the
/// document for each. If any of them throws, that is the receipt she could
/// not get.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
  });
  tearDown(() async => shop.close());

  Future<Uint8List> receiptFor(int id) async {
    final OrderRecord? order = await shop.sales.orderById(id);
    return ReceiptDocument(order: order!, settings: shop.settings).build();
  }

  void expectAReceipt(Uint8List bytes) {
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
  }

  Future<CompletedOrder> aSale({bool unpaid = false}) async => shop.sell(
    OrderDraft(
      items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
      paymentMethod: unpaid ? null : PaymentMethod.cash,
      unpaid: unpaid,
    ),
  );

  test('an ordinary sale', () async {
    expectAReceipt(await receiptFor((await aSale()).id));
  });

  test('one she has corrected', () async {
    final CompletedOrder sold = await aSale();
    await shop.orders.revise(
      orderId: sold.id,
      draft: OrderDraft(
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Large', quantity: 2),
          await shop.item('Iced Black', 'Small', lineId: 'line-2'),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
      settings: shop.settings,
    );
    expectAReceipt(await receiptFor(sold.id));
  });

  test('one she has corrected twice', () async {
    final CompletedOrder sold = await aSale();
    for (int i = 0; i < 2; i++) {
      await shop.orders.revise(
        orderId: sold.id,
        draft: OrderDraft(
          items: <DraftItem>[
            await shop.item('Iced Black', 'Large', lineId: 'r$i'),
          ],
          paymentMethod: PaymentMethod.cash,
        ),
        settings: shop.settings,
      );
    }
    expectAReceipt(await receiptFor(sold.id));
  });

  test('one she has moved to another day', () async {
    final CompletedOrder sold = await aSale();
    await shop.sales.changeOrderDate(
      orderId: sold.id,
      day: DateTime(2026, 3, 14),
    );
    expectAReceipt(await receiptFor(sold.id));
  });

  test('one that is not paid for yet', () async {
    expectAReceipt(await receiptFor((await aSale(unpaid: true)).id));
  });

  test('one she corrected and then had paid for', () async {
    final CompletedOrder sold = await aSale(unpaid: true);
    await shop.orders.revise(
      orderId: sold.id,
      draft: OrderDraft(
        items: <DraftItem>[await shop.item('Iced Black', 'Large')],
        unpaid: true,
      ),
      settings: shop.settings,
    );
    await shop.sales.recordPayment(
      orderId: sold.id,
      method: PaymentMethod.cash,
    );
    expectAReceipt(await receiptFor(sold.id));
  });

  test('a voided one', () async {
    final CompletedOrder sold = await aSale();
    await shop.sales.voidOrder(orderId: sold.id, reason: 'Wrong order');
    expectAReceipt(await receiptFor(sold.id));
  });
}
