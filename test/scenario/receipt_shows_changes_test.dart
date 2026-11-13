import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// A receipt should say what was different about the drink, not recite what
/// the drink always is.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
  });
  tearDown(() async => shop.close());

  Future<OrderRecord> sell(List<DraftOption> options) async {
    final CompletedOrder done = await shop.sell(
      OrderDraft(
        items: <DraftItem>[
          await shop.item('Spanish Latte', 'Large', options: options),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    return (await shop.sales.orderById(done.id))!;
  }

  List<String> printed(OrderRecord order) => order.lines.single.options
      .where((OrderLineOption o) => o.isWorthPrinting)
      .map((OrderLineOption o) => o.label)
      .toList();

  test('a drink taken as it comes prints no choices at all', () async {
    // Every default: regular sweetness, regular strength, regular ice, the
    // milk it is made with.
    final OrderRecord order = await sell(<DraftOption>[
      await shop.draftOption('sweetness', 'Regular'),
      await shop.draftOption('strength', 'Regular'),
      await shop.draftOption('ice', 'Regular'),
      await shop.draftOption('milk', 'Full Cream'),
    ]);

    expect(printed(order), isEmpty);
    // The choices are still on the order; they are simply not printed.
    expect(order.lines.single.options.length, 4);
  });

  test('only what she changed is printed', () async {
    final OrderRecord order = await sell(<DraftOption>[
      await shop.draftOption('sweetness', 'Less Sweet'),
      await shop.draftOption('strength', 'Regular'),
      await shop.draftOption('ice', 'No Ice'),
    ]);

    // "No Ice" already says what it is about, so it keeps its own words.
    expect(printed(order), <String>['Less Sweet sweetness', 'No Ice']);
  });

  test('a changed milk is printed, the default one is not', () async {
    final OrderRecord oat = await sell(<DraftOption>[
      await shop.draftOption('milk', 'Oat'),
    ]);
    expect(printed(oat), <String>['Oat milk']);

    final OrderRecord plain = await sell(<DraftOption>[
      await shop.draftOption('milk', 'Full Cream'),
    ]);
    expect(printed(plain), isEmpty);
  });

  test('anything she was charged for is always printed', () async {
    // A line on the bill has to be explainable, default or not.
    final OrderRecord order = await sell(<DraftOption>[
      await shop.draftOption('extras', 'Sea Salt Cold Foam'),
    ]);
    expect(printed(order), <String>['Sea Salt Cold Foam']);
  });

  test('what was default is remembered from the sale, not looked up', () async {
    final OrderRecord order = await sell(<DraftOption>[
      await shop.draftOption('sweetness', 'Regular'),
    ]);
    expect(order.lines.single.options.single.wasDefault, isTrue);
    expect(
      order.lines.single.options.single.name,
      'Regular',
      reason: 'the choice is still on the record either way',
    );
  });
}
