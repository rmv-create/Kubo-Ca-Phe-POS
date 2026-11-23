import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/providers.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/menu.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';
import 'package:kubo_pos/features/pos/state/cart_controller.dart';

import '../support/pos_fixture.dart';

/// Correcting a finished order, the whole way through.
///
/// The barista tried it and got a second order instead of a corrected one.
/// Each piece had its own test — the service that corrects an order, the
/// tile that starts it, the button that finishes it — and not one of them
/// would notice a chain that comes apart in the middle: if the till forgets
/// which order it is correcting, pressing COMPLETE writes a brand new sale,
/// which is exactly what doubling looks like.
///
/// So this walks the chain the till walks: read the drinks back off the
/// order, put them on the screen as a correction, let somebody change them,
/// and finish. One order, start to end.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late ProviderContainer till;
  late CompletedOrder sold;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
    sold = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    till = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(shop.db),
        clockProvider.overrideWithValue(shop.clock),
        initialSettingsProvider.overrideWithValue(shop.settings),
      ],
    );
    addTearDown(till.dispose);
  });
  tearDown(() async => shop.close());

  /// What the orders list does when "Change this order" is tapped: read the
  /// drinks back, then hand them to the till as a correction.
  Future<void> putItBackOnTheScreen() async {
    final List<RepeatableLine> lines = await shop.sales.drinksToRingAgain(
      sold.id,
    );
    expect(lines, isNotEmpty);

    final List<DraftItem> carried = <DraftItem>[];
    for (final RepeatableLine line in lines) {
      final Product product = await shop.product('Spanish Latte');
      carried.add(
        DraftItem(
          lineId: 'carried-${carried.length}',
          product: product,
          size: product.sizes.firstWhere(
            (ProductSize s) => s.size.id == line.sizeId,
          ),
          quantity: line.quantity,
          options: const <DraftOption>[],
        ),
      );
    }

    till
        .read(cartProvider.notifier)
        .reviseOrder(
          orderId: sold.id,
          orderNo: sold.orderNo,
          items: carried,
          paymentMethod: PaymentMethod.cash,
        );
  }

  /// What the COMPLETE button does: correct the order it was given, or ring
  /// up a new sale when it was given none.
  Future<CompletedOrder> pressComplete() async {
    final OrderDraft draft = till.read(cartProvider);
    final int? revising = draft.revisingOrderId;
    return revising == null
        ? till
              .read(orderServiceProvider)
              .complete(draft, settings: till.read(settingsControllerProvider))
        : till
              .read(orderServiceProvider)
              .revise(
                orderId: revising,
                draft: draft,
                settings: till.read(settingsControllerProvider),
              );
  }

  test('it stays one order, with its own number', () async {
    await putItBackOnTheScreen();

    final CompletedOrder after = await pressComplete();

    expect(after.id, sold.id);
    expect(after.orderNo, sold.orderNo);
    expect(await shop.countOf('orders'), 1, reason: 'not two');
  });

  test('a drink added on the way does not start a new sale', () async {
    await putItBackOnTheScreen();

    final Product iced = await shop.product('Iced Black');
    till
        .read(cartProvider.notifier)
        .addItem(
          product: iced,
          size: iced.sizes.first,
          options: const <DraftOption>[],
        );

    expect(
      till.read(cartProvider).revisingOrderId,
      sold.id,
      reason: 'the till must still know which order it is correcting',
    );

    await pressComplete();

    expect(await shop.countOf('orders'), 1);
    expect((await shop.sales.orderById(sold.id))!.itemCount, 2);
  });

  test('a drink taken off does not start a new sale either', () async {
    await putItBackOnTheScreen();
    final String lineId = till.read(cartProvider).items.single.lineId;
    final Product iced = await shop.product('Iced Black');
    till
        .read(cartProvider.notifier)
        .addItem(
          product: iced,
          size: iced.sizes.first,
          options: const <DraftOption>[],
        );
    till.read(cartProvider.notifier).removeItem(lineId);

    expect(till.read(cartProvider).revisingOrderId, sold.id);

    await pressComplete();
    expect(await shop.countOf('orders'), 1);
    expect(
      (await shop.sales.orderById(sold.id))!.lines.single.productName,
      'Iced Black',
    );
  });

  test('changing the customer does not start a new sale', () async {
    await putItBackOnTheScreen();
    final int id = await shop.customers.create(name: 'Tita Baby');
    till.read(cartProvider.notifier).setCustomer(await shop.customers.byId(id));

    expect(till.read(cartProvider).revisingOrderId, sold.id);
    await pressComplete();
    expect(await shop.countOf('orders'), 1);
  });

  test('and once it is saved the till is free for the next customer', () async {
    await putItBackOnTheScreen();
    await pressComplete();
    till.read(cartProvider.notifier).clear();

    expect(
      till.read(cartProvider).revisingOrderId,
      isNull,
      reason: 'or the next sale would be written over this order',
    );
  });
}
