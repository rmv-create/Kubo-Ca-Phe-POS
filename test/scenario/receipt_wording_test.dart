import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// What a customisation reads as once it is on paper.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the words on the line', () {
    OrderLineOption opt(String name, String group) =>
        OrderLineOption(name: name, groupName: group, priceDelta: Money.zero);

    test('a choice is read beside the question it answers', () {
      // "Regular · Regular · Regular" answered nothing.
      expect(opt('Regular', 'Sweetness').label, 'Regular sweetness');
      expect(opt('Regular', 'Strength').label, 'Regular strength');
      // "Less Ice" already says what it is about, so it is left alone.
      expect(opt('Less Ice', 'Ice').label, 'Less Ice');
      expect(opt('Regular', 'Ice').label, 'Regular ice');
    });

    test('an extra keeps its own name', () {
      expect(
        opt('Sea Salt Cold Foam', 'Extras').label,
        'Sea Salt Cold Foam',
        reason: 'not "Sea Salt Cold Foam extras"',
      );
      expect(opt('1g Matcha', 'Extras').label, '1g Matcha');
    });

    test('a name that already says the group is not said twice', () {
      expect(opt('Oat Milk', 'Milk').label, 'Oat Milk');
    });

    test('a group nobody named is left alone', () {
      expect(opt('Regular', '').label, 'Regular');
    });
  });

  group('on a real order', () {
    late PosFixture shop;

    setUp(() async {
      shop = await PosFixture.open();
      final Ingredient beans = await shop.addIngredient(
        'Coffee beans',
        price: Money.of(1200),
        openingStock: 5000,
      );
      await shop.setRecipe('Spanish Latte', 'Large', <Ingredient, double>{
        beans: 20,
      });
    });
    tearDown(() async => shop.close());

    test('the group it was chosen from is kept with the sale', () async {
      final CompletedOrder done = await shop.sell(
        OrderDraft(
          items: <DraftItem>[
            await shop.item(
              'Spanish Latte',
              'Large',
              options: <DraftOption>[
                await shop.draftOption('sweetness', 'Regular'),
              ],
            ),
          ],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      final OrderRecord record = (await shop.sales.orderById(done.id))!;
      final OrderLineOption option = record.lines.single.options.single;
      expect(option.name, 'Regular');
      expect(option.groupName, 'Sweetness');
      expect(option.label, 'Regular sweetness');
    });
  });
}
