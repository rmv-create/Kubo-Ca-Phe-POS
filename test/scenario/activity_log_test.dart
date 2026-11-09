import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/core/quantity/measurement_unit.dart';
import 'package:kubo_pos/core/quantity/quantity.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/services/activity_log.dart';

import '../support/pos_fixture.dart';

/// Everything that happened, and who did it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late ActivityLog log;

  setUp(() async {
    shop = await PosFixture.open();
    log = ActivityLog(shop.db);
  });
  tearDown(() async => shop.close());

  Future<CompletedOrder> sell() async => shop.sell(
    OrderDraft(
      items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  test('an order, a void and a spill all land in it', () async {
    final CompletedOrder done = await sell();
    await shop.sales.voidOrder(orderId: done.id, reason: 'Rung up twice');
    final Ingredient beans = await shop.addIngredient(
      'Coffee',
      price: Money.of(900),
      openingStock: 1000,
    );
    await shop.stock.recordWaste(
      ingredientId: beans.id,
      quantity: Quantity.fromBase(20, BaseUnit.gram),
      reason: WasteReason.spill,
    );

    final List<ActivityEntry> entries = await log.recent();
    final List<String> actions =
        entries.map((ActivityEntry e) => e.action).toList();

    expect(actions, contains('order_completed'));
    expect(actions, contains('order_voided'));
    expect(actions, contains('waste_recorded'));
  });

  test('newest first, so the last thing done is the first thing seen',
      () async {
    await sell();
    shop.clock.advance(const Duration(minutes: 5));
    final CompletedOrder second = await sell();

    final List<ActivityEntry> entries = await log.recent();
    expect(entries.first.summary, contains(second.orderNo));
  });

  test('a void is flagged as worth noticing; an ordinary order is not',
      () async {
    final CompletedOrder done = await sell();
    await shop.sales.voidOrder(orderId: done.id, reason: 'Mistake');

    final List<ActivityEntry> entries = await log.recent();
    expect(
      entries.firstWhere((ActivityEntry e) => e.action == 'order_voided')
          .isNotable,
      isTrue,
    );
    expect(
      entries.firstWhere((ActivityEntry e) => e.action == 'order_completed')
          .isNotable,
      isFalse,
    );
  });

  test('it records who was at the till', () async {
    // The column has existed since staff PINs were added and nothing ever
    // wrote to it: every entry said what happened and none said who.
    final PosFixture withBarista = await PosFixture.open(separate: true);
    addTearDown(withBarista.close);
    final ActivityLog theirs = ActivityLog(withBarista.db);

    await withBarista.sellAs('Ana');

    final List<ActivityEntry> entries = await theirs.recent();
    expect(entries.first.actor, 'Ana');
  });

  test('nobody signed in leaves it blank rather than guessing', () async {
    await sell();
    expect((await log.recent()).first.actor, isNull);
  });

  test('one day can be read on its own', () async {
    await sell();
    final String today = shop.reports.today;
    shop.clock.advance(const Duration(days: 1));
    await sell();

    final List<ActivityEntry> justToday = await log.recent(
      businessDate: today,
    );
    expect(justToday, isNotEmpty);
    expect(
      justToday.every((ActivityEntry e) => e.businessDate == today),
      isTrue,
    );
    expect((await log.days()).length, 2);
  });
}
