import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/menu.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/features/pos/state/cart_controller.dart';

/// Sample menu rows, not the shop's real data — this file is about the cart's
/// behaviour, not about prices.
const DrinkSize _grande = DrinkSize(
  id: 2,
  code: 'grande',
  name: 'Grande',
  volumeOz: 16,
  displayOrder: 1,
  isActive: true,
);

final Product _latte = Product(
  id: 1,
  categoryId: 1,
  name: 'Sample Latte',
  description: null,
  displayOrder: 0,
  isActive: true,
  isArchived: false,
  sizes: <ProductSize>[
    ProductSize(
      id: 1,
      productId: 1,
      size: _grande,
      price: Money.of(100),
      isAvailable: true,
      isDefaultSize: true,
    ),
  ],
);

ProductSize get _size => _latte.sizes.single;

const CustomizationGroup _milk = CustomizationGroup(
  id: 1,
  code: 'milk',
  name: 'Milk',
  selectionType: SelectionType.single,
  minSelect: 0,
  maxSelect: 1,
  isRequired: true,
  isProactive: true,
  displayOrder: 0,
  isActive: true,
);

final DraftOption _oat = DraftOption(
  group: _milk,
  option: CustomizationOption(
    id: 10,
    groupId: 1,
    name: 'Oat',
    priceDelta: Money.of(20),
    displayOrder: 0,
    isActive: true,
  ),
);

void main() {
  late ProviderContainer container;
  CartController cart() => container.read(cartProvider.notifier);
  OrderDraft draft() => container.read(cartProvider);

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  group('building an order', () {
    test('starts empty and cannot be completed', () {
      expect(draft().isEmpty, isTrue);
      expect(draft().canComplete, isFalse);
      expect(draft().total, Money.zero);
    });

    test('adds drinks and totals them', () {
      cart().addItem(product: _latte, size: _size, options: <DraftOption>[]);
      cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[_oat],
      );

      expect(draft().items.length, 2);
      expect(draft().drinkCount, 2);
      expect(draft().total, Money.of(220));
    });

    test('every line gets its own identity, even when identical', () {
      final DraftItem a = cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[],
      );
      final DraftItem b = cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[],
      );
      expect(a.lineId, isNot(b.lineId));
      expect(
        a.signature,
        b.signature,
        reason: 'the same drink still has the same signature',
      );
    });

    test('quantity steps up and down', () {
      final DraftItem item = cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[],
      );
      cart().increment(item.lineId);
      cart().increment(item.lineId);
      expect(draft().items.single.quantity, 3);
      expect(draft().total, Money.of(300));

      cart().decrement(item.lineId);
      expect(draft().items.single.quantity, 2);
    });

    test('stepping below one removes the line rather than leaving a zero', () {
      final DraftItem item = cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[],
      );
      cart().decrement(item.lineId);
      expect(draft().isEmpty, isTrue);
    });

    test('duplicate repeats the drink without rebuilding it', () {
      final DraftItem item = cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[_oat],
      );
      cart().duplicateItem(item.lineId);

      expect(draft().items.length, 2);
      expect(draft().items.last.options.single.option.name, 'Oat');
      expect(draft().items.last.lineId, isNot(item.lineId));
      expect(draft().total, Money.of(240));
    });

    test('a duplicate lands next to its original', () {
      final DraftItem first = cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[],
      );
      cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[_oat],
      );
      cart().duplicateItem(first.lineId);

      expect(draft().items[1].signature, first.signature);
    });

    test('editing a line changes only that line', () {
      final DraftItem a = cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[],
      );
      final DraftItem b = cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[],
      );
      cart().replaceItem(a.lineId, a.copyWith(options: <DraftOption>[_oat]));

      expect(draft().items.first.options.length, 1);
      expect(draft().items.last.lineId, b.lineId);
      expect(draft().items.last.options, isEmpty);
    });

    test('removing takes out the right line', () {
      final DraftItem a = cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[],
      );
      final DraftItem b = cart().addItem(
        product: _latte,
        size: _size,
        options: <DraftOption>[_oat],
      );
      cart().removeItem(a.lineId);
      expect(draft().items.single.lineId, b.lineId);
    });
  });

  group('payment', () {
    setUp(() {
      cart().addItem(product: _latte, size: _size, options: <DraftOption>[]);
    });

    test('cash is ready as soon as it is chosen', () {
      cart().setPaymentMethod(PaymentMethod.cash);
      expect(draft().canComplete, isTrue);
    });

    test('GCash is not, until it is confirmed', () {
      cart().setPaymentMethod(PaymentMethod.gcash);
      expect(draft().canComplete, isFalse);
      cart().setGcashConfirmed(true);
      expect(draft().canComplete, isTrue);
    });

    test('switching away from GCash drops the confirmation', () {
      cart().setPaymentMethod(PaymentMethod.gcash);
      cart().setGcashConfirmed(true);
      cart().setPaymentMethod(PaymentMethod.cash);
      cart().setPaymentMethod(PaymentMethod.gcash);
      expect(
        draft().gcashConfirmed,
        isFalse,
        reason: 'a confirmation must never carry over to a new selection',
      );
      expect(draft().canComplete, isFalse);
    });

    test('change is worked out from what was handed over', () {
      cart().setPaymentMethod(PaymentMethod.cash);
      cart().setTendered(Money.of(500));
      expect(draft().change, Money.of(400));
    });

    test('handing over too little is not negative change', () {
      cart().setPaymentMethod(PaymentMethod.cash);
      cart().setTendered(Money.of(50));
      expect(draft().change, Money.zero);
    });

    test('change only applies to cash', () {
      cart().setPaymentMethod(PaymentMethod.gcash);
      cart().setTendered(Money.of(500));
      expect(draft().change, Money.zero);
    });
  });

  test('clearing returns to an empty order, ready for the next customer', () {
    cart().addItem(product: _latte, size: _size, options: <DraftOption>[]);
    cart().setPaymentMethod(PaymentMethod.cash);
    cart().clear();

    expect(draft().isEmpty, isTrue);
    expect(draft().paymentMethod, isNull);
    expect(draft().customer, isNull);
    expect(draft().gcashConfirmed, isFalse);
    expect(draft().total, Money.zero);
  });
}
