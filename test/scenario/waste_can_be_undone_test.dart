import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/money/unit_cost.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';

import '../support/pos_fixture.dart';

/// Waste used to be write-only. A slip of the finger that said 500 g instead
/// of 50 g took 450 g off the shelf and out of the month, and nothing could
/// be done about it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late Ingredient beans;

  setUp(() async {
    shop = await PosFixture.open();
    // SAMPLE cost: ₱1,200 a kilo, so ₱1.20 a gram.
    beans = await shop.addIngredient(
      'Coffee beans',
      price: Money.of(1200),
      openingStock: 5000,
    );
  });

  tearDown(() async => shop.close());

  Future<double> onHand() async => (await shop.stockOf(beans.id))!.milli / 1000;

  Future<int> record(double grams) => shop.stock.recordWaste(
    ingredientId: beans.id,
    quantity: Quantity.fromBase(grams, BaseUnit.gram),
    reason: WasteReason.spill,
  );

  group('taking it back', () {
    test('puts the stock back on the shelf', () async {
      final double before = await onHand();
      final int id = await record(500);
      expect(await onHand(), before - 500);

      await shop.stock.voidWaste(id: id, reason: 'Typed 500 for 50');

      expect(await onHand(), before);
    });

    test('stops it counting against the month', () async {
      final int id = await record(500);
      final String today = shop.reports.today;
      expect((await shop.reports.forDay(today)).waste, Money.of(600));

      await shop.stock.voidWaste(id: id, reason: 'Mistake');

      expect((await shop.reports.forDay(today)).waste, Money.zero);
    });

    test('leaves it in the list, marked', () async {
      final int id = await record(500);
      await shop.stock.voidWaste(id: id, reason: 'Mistake');

      final WasteEntry entry = (await shop.stock.waste()).single;
      expect(entry.isVoided, isTrue);
      expect(entry.voidReason, 'Mistake');
    });

    test('cannot be done twice', () async {
      final int id = await record(500);
      await shop.stock.voidWaste(id: id, reason: 'Mistake');

      expect(
        () => shop.stock.voidWaste(id: id, reason: 'Again'),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('needs a reason', () async {
      final int id = await record(500);
      expect(
        () => shop.stock.voidWaste(id: id, reason: '  '),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('correcting it', () {
    test('moves only the difference', () async {
      final double before = await onHand();
      final int id = await record(500);

      await shop.stock.updateWaste(
        id: id,
        quantity: Quantity.fromBase(50, BaseUnit.gram),
      );

      expect(await onHand(), before - 50, reason: '450 g comes back');
    });

    test('and more waste takes more off', () async {
      final double before = await onHand();
      final int id = await record(50);

      await shop.stock.updateWaste(
        id: id,
        quantity: Quantity.fromBase(80, BaseUnit.gram),
      );

      expect(await onHand(), before - 80);
    });

    test('re-values it at the cost it was written down at', () async {
      final int id = await record(500);
      // The price of coffee changes after the fact.
      await shop.stock.recordCost(
        ingredientId: beans.id,
        cost: UnitCost.perPurchaseUnit(
          price: Money.of(2400),
          baseUnitsPerPurchaseUnit: 1000,
          unit: BaseUnit.gram,
        ),
      );

      await shop.stock.updateWaste(
        id: id,
        quantity: Quantity.fromBase(50, BaseUnit.gram),
      );

      // 50 g at the ₱1.20 a gram it was recorded at, not today's ₱2.40.
      expect((await shop.stock.waste()).single.value, Money.of(60));
    });

    test('the reason and the note can be changed on their own', () async {
      final int id = await record(500);
      final double after = await onHand();

      await shop.stock.updateWaste(
        id: id,
        reason: WasteReason.spoiled,
        notes: 'Left out overnight',
      );

      final WasteEntry entry = (await shop.stock.waste()).single;
      expect(entry.reason, WasteReason.spoiled);
      expect(entry.notes, 'Left out overnight');
      expect(await onHand(), after, reason: 'nothing moved');
    });

    test('an entry already taken back is not corrected', () async {
      final int id = await record(500);
      await shop.stock.voidWaste(id: id, reason: 'Mistake');

      expect(
        () => shop.stock.updateWaste(
          id: id,
          quantity: Quantity.fromBase(50, BaseUnit.gram),
        ),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('nothing is wasted by correcting to zero', () async {
      final int id = await record(500);
      expect(
        () => shop.stock.updateWaste(
          id: id,
          quantity: Quantity.fromBase(0, BaseUnit.gram),
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('an entry that is gone says so', () async {
      expect(
        () => shop.stock.voidWaste(id: 9999, reason: 'Mistake'),
        throwsA(isA<NotFoundException>()),
      );
    });
  });
}
