import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/menu.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// What a customisation is made of, and changing it.
///
/// The amounts were in the app from the start — Sea Salt Cold Foam is 20 g
/// of cream, 30 g of fresh milk, 10 g of condensed and 0.6 g of salt — but
/// no screen ever showed them, so she could not check one or change one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
  });
  tearDown(() async => shop.close());

  Future<int> optionId(String group, String name) async {
    final DraftOption option = await shop.draftOption(group, name);
    return option.option.id;
  }

  test('the sea salt foam says what it is made of', () async {
    final List<OptionEffect> lines = await shop.recipeBook.effectsForOption(
      await optionId('extras', 'Sea Salt Cold Foam'),
    );

    expect(lines.map((OptionEffect l) => l.ingredientName).toSet(), <String>{
      'Nestle All Purpose Cream',
      'Alaska Fresh Milk',
      'Vinamilk Condensed',
      'Sea Salt',
    });
    // And what each one costs her, so the screen can add them up.
    expect(lines.every((OptionEffect l) => l.cost != null), isTrue);
  });

  test('a swap reads as taking something out', () async {
    final List<OptionEffect> lines = await shop.recipeBook.effectsForOption(
      await optionId('milk', 'Oat'),
    );
    expect(lines.any((OptionEffect l) => l.takesOut), isTrue);
    expect(lines.any((OptionEffect l) => !l.takesOut), isTrue);
    // Oat is per drink, not a rule for everything.
    expect(lines.every((OptionEffect l) => l.isForEveryDrink), isFalse);
  });

  group('changing it', () {
    test('an amount she changes is what the next drink costs', () async {
      final int foam = await optionId('extras', 'Sea Salt Cold Foam');
      final OrderRecord before = await _sellWithFoam(shop);

      // She pours more cream than the sheet said.
      final OptionEffect cream = (await shop.recipeBook.effectsForOption(foam))
          .firstWhere(
            (OptionEffect l) => l.ingredientName == 'Nestle All Purpose Cream',
          );
      await shop.recipeBook.saveEffect(
        optionId: foam,
        ingredientId: cream.ingredientId,
        delta: Quantity.fromBase(40, BaseUnit.gram),
      );

      final OrderRecord after = await _sellWithFoam(shop);
      expect(after.cogs > before.cogs, isTrue);
    });

    test('a line she adds comes out of stock', () async {
      final int foam = await optionId('extras', 'Sea Salt Cold Foam');
      final List<OptionEffect> before = await shop.recipeBook.effectsForOption(
        foam,
      );

      final int matcha = (await shop.stock.ingredients())
          .firstWhere((Ingredient i) => i.name == 'Matcha')
          .id;
      await shop.recipeBook.saveEffect(
        optionId: foam,
        ingredientId: matcha,
        delta: Quantity.fromBase(2, BaseUnit.gram),
      );

      final List<OptionEffect> after = await shop.recipeBook.effectsForOption(
        foam,
      );
      expect(after.length, before.length + 1);
    });

    test('an amount of zero removes the line', () async {
      final int foam = await optionId('extras', 'Sea Salt Cold Foam');
      final OptionEffect salt = (await shop.recipeBook.effectsForOption(
        foam,
      )).firstWhere((OptionEffect l) => l.ingredientName == 'Sea Salt');

      await shop.recipeBook.saveEffect(
        optionId: foam,
        ingredientId: salt.ingredientId,
        delta: Quantity.fromBase(0, BaseUnit.gram),
      );

      expect(
        (await shop.recipeBook.effectsForOption(
          foam,
        )).where((OptionEffect l) => l.ingredientName == 'Sea Salt'),
        isEmpty,
      );
    });

    test('removing a line leaves the rest alone', () async {
      final int foam = await optionId('extras', 'Sea Salt Cold Foam');
      final OptionEffect salt = (await shop.recipeBook.effectsForOption(
        foam,
      )).firstWhere((OptionEffect l) => l.ingredientName == 'Sea Salt');

      await shop.recipeBook.removeEffect(
        optionId: foam,
        ingredientId: salt.ingredientId,
      );

      final List<OptionEffect> left = await shop.recipeBook.effectsForOption(
        foam,
      );
      expect(left.length, 3);
      expect(
        left.map((OptionEffect l) => l.ingredientName),
        contains('Alaska Fresh Milk'),
      );
    });

    test('saving the same line twice does not make two of it', () async {
      final int foam = await optionId('extras', 'Sea Salt Cold Foam');
      final OptionEffect salt = (await shop.recipeBook.effectsForOption(
        foam,
      )).firstWhere((OptionEffect l) => l.ingredientName == 'Sea Salt');
      final int before = (await shop.recipeBook.effectsForOption(foam)).length;

      await shop.recipeBook.saveEffect(
        optionId: foam,
        ingredientId: salt.ingredientId,
        delta: Quantity.fromBase(1, BaseUnit.gram),
      );
      await shop.recipeBook.saveEffect(
        optionId: foam,
        ingredientId: salt.ingredientId,
        delta: Quantity.fromBase(2, BaseUnit.gram),
      );

      final List<OptionEffect> after = await shop.recipeBook.effectsForOption(
        foam,
      );
      expect(after.length, before);
      expect(
        after
            .firstWhere((OptionEffect l) => l.ingredientName == 'Sea Salt')
            .delta
            .inBaseUnits,
        2,
      );
    });
  });
}

Future<OrderRecord> _sellWithFoam(PosFixture shop) async {
  final CompletedOrder done = await shop.sell(
    OrderDraft(
      items: <DraftItem>[
        await shop.item(
          'Spanish Latte',
          'Large',
          options: <DraftOption>[
            await shop.draftOption('extras', 'Sea Salt Cold Foam'),
          ],
        ),
      ],
      paymentMethod: PaymentMethod.cash,
    ),
  );
  return (await shop.sales.orderById(done.id))!;
}
