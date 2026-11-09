import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// Her customers, as a book she can look things up in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;

  setUp(() async => shop = await PosFixture.open());
  tearDown(() async => shop.close());

  Future<Customer> regular(String name, {String? mobile}) async {
    final int id = await shop.customers.create(name: name, mobile: mobile);
    return (await shop.customers.byId(id))!;
  }

  Future<void> buy(Customer who, {bool unpaid = false}) async {
    await shop.sell(
      OrderDraft(
        customer: who,
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: unpaid ? null : PaymentMethod.cash,
        unpaid: unpaid,
      ),
    );
  }

  group('finding somebody', () {
    test('by name, however she types it', () async {
      await regular('Tita Baby');
      expect((await shop.customers.search('tita')).single.name, 'Tita Baby');
      expect((await shop.customers.search('BABY')).single.name, 'Tita Baby');
    });

    test('by mobile, spaces and dashes and all', () async {
      await regular('Tita Baby', mobile: '0917 555 1234');

      for (final String typed in <String>[
        '09175551234',
        '0917 555 1234',
        '0917-555-1234',
      ]) {
        expect(
          (await shop.customers.search(typed)).single.name,
          'Tita Baby',
          reason: 'typed as "$typed"',
        );
      }
    });
  });

  group('their history', () {
    test('counts the orders and remembers the first and the last', () async {
      final Customer who = await regular('Tita Baby');
      await buy(who);
      shop.clock.advance(const Duration(days: 3));
      await buy(who);

      final Customer after = (await shop.customers.byId(who.id))!;

      expect(after.orderCount, 2);
      expect(after.totalSpend, Money.of(278));
      expect(after.averageOrderValue, Money.of(139));
      expect(after.firstVisitAt, isNotNull);
      expect(after.lastVisitAt, isNotNull);
      expect(
        after.lastVisitAt!.isAfter(after.firstVisitAt!),
        isTrue,
        reason: 'three days apart',
      );
    });

    test('an unpaid order is in the history and in what they owe', () async {
      final Customer who = await regular('Tita Baby');
      await buy(who);
      await buy(who, unpaid: true);

      final Customer after = (await shop.customers.byId(who.id))!;
      expect(after.orderCount, 2);

      final List<OrderRecord> orders = await shop.sales.orders(
        customerId: who.id,
        limit: 100,
      );
      final Money owed = orders
          .where((OrderRecord o) => o.paymentState == 'unpaid')
          .fold(Money.zero, (Money a, OrderRecord o) => a + o.total);
      expect(owed, Money.of(139));
    });

    test('a guest order belongs to nobody and stays out of the book',
        () async {
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      expect(await shop.customers.search(''), isEmpty);
    });
  });

  group('what did you have last time', () {
    test('answers from the first repeat, before a usual exists', () async {
      final Customer who = await regular('Tita Baby');
      await buy(who);

      // One order: there is no "usual" yet, because nothing has repeated.
      expect(await shop.customers.usualFor(who.id), isNull);

      // But "what did you have last time?" has an answer.
      final UsualOrder? last = await shop.customers.lastOrderedFor(who.id);
      expect(last, isNotNull);
      expect(last!.productName, 'Spanish Latte');
      expect(last.sizeName, 'Large');
      expect(last.isSaved, isFalse);
    });

    test('is the most recent drink, not the most repeated one', () async {
      final Customer who = await regular('Tita Baby');
      await buy(who);
      await buy(who);

      shop.clock.advance(const Duration(days: 1));
      await shop.sell(
        OrderDraft(
          customer: who,
          items: <DraftItem>[await shop.item('Iced Black', 'Small')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      // The usual is still the latte — it has come up twice.
      expect((await shop.customers.usualFor(who.id))!.productName,
          'Spanish Latte');
      // Last time was the Iced Black, which is what she would be asked.
      expect((await shop.customers.lastOrderedFor(who.id))!.productName,
          'Iced Black');
    });

    test('a customer who has never ordered has nothing to repeat', () async {
      final Customer who = await regular('Tita Baby');
      expect(await shop.customers.lastOrderedFor(who.id), isNull);
    });
  });

  group('who stopped coming', () {
    test('a weekly regular gone a month is missed', () async {
      final Customer who = await regular('Tita Baby');
      for (int week = 0; week < 6; week++) {
        await buy(who);
        shop.clock.advance(const Duration(days: 7));
      }
      shop.clock.advance(const Duration(days: 30));

      final List<LapsedCustomer> gone = await shop.customers.lapsed();

      expect(gone, hasLength(1));
      expect(gone.single.customer.name, 'Tita Baby');
      expect(gone.single.daysAway, greaterThan(30));
      expect(gone.single.rhythm, 'Came about weekly');
    });

    test('a weekly regular who came yesterday is not', () async {
      final Customer who = await regular('Tita Baby');
      for (int week = 0; week < 6; week++) {
        await buy(who);
        shop.clock.advance(const Duration(days: 7));
      }

      expect(await shop.customers.lapsed(), isEmpty);
    });

    test('somebody who only ever comes monthly is not missed after ten days',
        () async {
      final Customer who = await regular('Tito Ben');
      for (int month = 0; month < 4; month++) {
        await buy(who);
        shop.clock.advance(const Duration(days: 30));
      }
      // Ten days past their last visit is nothing for this person.
      shop.clock.set(shop.clock.now().subtract(const Duration(days: 20)));

      expect(
        await shop.customers.lapsed(),
        isEmpty,
        reason: 'their own rhythm is monthly, not weekly',
      );
    });

    test('a one-off visitor is not a regular who stopped', () async {
      final Customer who = await regular('Walk-in Wally');
      await buy(who);
      shop.clock.advance(const Duration(days: 90));

      expect(
        await shop.customers.lapsed(),
        isEmpty,
        reason: 'one order is not a rhythm to have broken',
      );
    });

    test('the one worth most is listed first', () async {
      final Customer small = await regular('Small Spender');
      final Customer big = await regular('Big Spender');
      for (int i = 0; i < 3; i++) {
        await buy(small);
        await buy(big);
        await buy(big);
        shop.clock.advance(const Duration(days: 7));
      }
      shop.clock.advance(const Duration(days: 40));

      final List<LapsedCustomer> gone = await shop.customers.lapsed();
      expect(gone.first.customer.name, 'Big Spender');
    });
  });

  group('what she can add herself', () {
    test('a birthday, month and day, with no year to ask for', () async {
      final Customer who = await regular('Tita Baby');

      await shop.customers.update(who.copyWith(birthday: '03-14'));
      final Customer after = (await shop.customers.byId(who.id))!;

      expect(after.birthday, '03-14');
      expect(after.birthdayLabel, '14 March');
    });

    test('and can take it off again', () async {
      final Customer who = await regular('Tita Baby');
      await shop.customers.update(who.copyWith(birthday: '03-14'));

      final Customer with_ = (await shop.customers.byId(who.id))!;
      await shop.customers.update(with_.copyWith(clearBirthday: true));

      expect((await shop.customers.byId(who.id))!.birthday, isNull);
      expect((await shop.customers.byId(who.id))!.birthdayLabel, isNull);
    });

    test('a note, and being marked VIP by hand', () async {
      final Customer who = await regular('Tita Baby');

      await shop.customers.update(
        who.copyWith(notes: 'Oat milk, no sugar', storedSegment: CustomerSegment.vip),
      );
      final Customer after = (await shop.customers.byId(who.id))!;

      expect(after.notes, 'Oat milk, no sugar');
      expect(after.storedSegment, CustomerSegment.vip);
    });

    test('renaming somebody does not wipe what she wrote about them',
        () async {
      // The reason `copyWith` exists: the edit screen used to rebuild the
      // whole customer by hand, so every field added later was one that
      // could be silently dropped by a rename.
      final Customer who = await regular('Tita Baby', mobile: '09175551234');
      await shop.customers.update(
        who.copyWith(birthday: '03-14', notes: 'Oat milk'),
      );

      final Customer loaded = (await shop.customers.byId(who.id))!;
      await shop.customers.update(loaded.copyWith(name: 'Tita Babes'));

      final Customer after = (await shop.customers.byId(who.id))!;
      expect(after.name, 'Tita Babes');
      expect(after.birthday, '03-14');
      expect(after.notes, 'Oat milk');
      expect(after.mobile, '09175551234');
    });
  });
}
