import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';

/// Which number the next order gets, and who decides.
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

  Future<CompletedOrder> sell() async => shop.sell(
    OrderDraft(
      items: <DraftItem>[await shop.item('Iced Black', 'Large')],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  test('the first order takes the number she chose', () async {
    shop.settings = shop.settings.copyWith(
      orderNumberStart: 1001,
      orderNumberPrefix: 'KUBO',
    );
    expect((await sell()).orderNo, 'KUBO-1001');
  });

  test('and the ones after it follow on', () async {
    shop.settings = shop.settings.copyWith(
      orderNumberStart: 1001,
      orderNumberPrefix: 'KUBO',
    );
    await sell();
    expect((await sell()).orderNo, 'KUBO-1002');
  });

  test('she can move the counter on after selling', () async {
    // The thing that used to be impossible: the field was locked the moment
    // anything had been rung up, and setting it did nothing anyway.
    shop.settings = shop.settings.copyWith(
      orderNumberStart: 1001,
      orderNumberPrefix: 'KUBO',
    );
    await sell();
    await sell();

    shop.settings = shop.settings.copyWith(orderNumberStart: 2000);

    expect((await sell()).orderNo, 'KUBO-2000');
    expect((await sell()).orderNo, 'KUBO-2001');
  });

  test('it never falls back onto a number already used', () async {
    shop.settings = shop.settings.copyWith(
      orderNumberStart: 1001,
      orderNumberPrefix: 'KUBO',
    );
    await sell();
    await sell();

    // Asking for a start that is behind the counter is ignored rather than
    // obeyed: two receipts must never share a number.
    shop.settings = shop.settings.copyWith(orderNumberStart: 1);

    expect((await sell()).orderNo, 'KUBO-1003');
  });

  test('deleting the practice orders frees the number again', () async {
    shop.settings = shop.settings.copyWith(
      orderNumberStart: 1001,
      orderNumberPrefix: 'KUBO',
    );
    final CompletedOrder first = await sell();
    final CompletedOrder second = await sell();

    await shop.sales.deleteOrder(orderId: first.id, reason: 'Practice');
    await shop.sales.deleteOrder(orderId: second.id, reason: 'Practice');

    expect(await shop.sales.highestOrderSequence(), 0);
    expect((await sell()).orderNo, 'KUBO-1001');
  });

  group('the number shown while she rings one up', () {
    test('is the number that order will actually get', () async {
      shop.settings = shop.settings.copyWith(
        orderNumberStart: 1001,
        orderNumberPrefix: 'KUBO',
      );
      final String shown = await shop.orders.nextOrderNumber(
        settings: shop.settings,
      );
      expect(shown, 'KUBO-1001');
      expect((await sell()).orderNo, shown);
    });

    test('moves on after each sale', () async {
      shop.settings = shop.settings.copyWith(
        orderNumberStart: 1001,
        orderNumberPrefix: 'KUBO',
      );
      await sell();
      expect(
        await shop.orders.nextOrderNumber(settings: shop.settings),
        'KUBO-1002',
      );
      await sell();
      expect(
        await shop.orders.nextOrderNumber(settings: shop.settings),
        'KUBO-1003',
      );
    });

    test('takes nothing — asking twice gives the same answer', () async {
      shop.settings = shop.settings.copyWith(orderNumberStart: 1001);
      final String once = await shop.orders.nextOrderNumber(
        settings: shop.settings,
      );
      final String twice = await shop.orders.nextOrderNumber(
        settings: shop.settings,
      );
      expect(once, twice);
      expect(await shop.sales.highestOrderSequence(), 0);
    });
  });

  test('the highest so far is what Settings guards against', () async {
    expect(await shop.sales.highestOrderSequence(), 0);
    shop.settings = shop.settings.copyWith(orderNumberStart: 1001);
    await sell();
    expect(await shop.sales.highestOrderSequence(), 1001);
  });
}
