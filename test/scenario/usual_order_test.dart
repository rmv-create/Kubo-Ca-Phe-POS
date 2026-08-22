import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/menu.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late int mariaId;

  setUp(() async {
    shop = await PosFixture.open();
    mariaId = await shop.customers.create(name: 'Maria Santos');
  });

  tearDown(() async => shop.close());

  Future<void> order(
    String product,
    String size, {
    List<DraftOption> options = const <DraftOption>[],
    int quantity = 1,
  }) async {
    final Customer customer = (await shop.customers.byId(mariaId))!;
    await shop.sell(
      OrderDraft(
        customer: customer,
        items: <DraftItem>[
          await shop.item(product, size, options: options, quantity: quantity),
        ],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    shop.clock.advance(const Duration(days: 1));
  }

  group('learning the usual', () {
    test('one order is not a usual', () async {
      await order('Spanish Latte', 'Grande');
      expect(await shop.customers.usualFor(mariaId), isNull);
    });

    test('the same drink twice becomes the usual', () async {
      await order('Spanish Latte', 'Grande');
      await order('Spanish Latte', 'Grande');

      final UsualOrder usual = (await shop.customers.usualFor(mariaId))!;
      expect(usual.productName, 'Spanish Latte');
      expect(usual.sizeName, 'Grande');
      expect(usual.pattern.occurrenceCount, 2);
      expect(usual.isSaved, isFalse);
      expect(usual.price, Money.of(139));
    });

    test('the usual is what repeats, not what was ordered last', () async {
      // Three Spanish Lattes over three visits, then one Matcha today.
      await order('Spanish Latte', 'Grande');
      await order('Spanish Latte', 'Grande');
      await order('Spanish Latte', 'Grande');
      await order('Matcha Oat Latte', 'Grande');

      final UsualOrder usual = (await shop.customers.usualFor(mariaId))!;
      expect(
        usual.productName,
        'Spanish Latte',
        reason: 'the most recent order is not the usual',
      );
      expect(usual.pattern.occurrenceCount, 3);
    });

    test(
      'the configuration is part of the usual, not just the drink',
      () async {
        final DraftOption oat = await shop.draftOption('milk', 'Oat');
        final DraftOption lessIce = await shop.draftOption('ice', 'Less Ice');

        await order(
          'Spanish Latte',
          'Grande',
          options: <DraftOption>[oat, lessIce],
        );
        await order(
          'Spanish Latte',
          'Grande',
          options: <DraftOption>[oat, lessIce],
        );

        final UsualOrder usual = (await shop.customers.usualFor(mariaId))!;
        expect(usual.optionNames, containsAll(<String>['Oat', 'Less Ice']));
        // 139 base + 20 oat + 0 less ice
        expect(usual.price, Money.of(159));
      },
    );

    test('the same drink with different milk is a different usual', () async {
      final DraftOption oat = await shop.draftOption('milk', 'Oat');
      final DraftOption full = await shop.draftOption('milk', 'Full Cream');

      await order('Spanish Latte', 'Grande', options: <DraftOption>[oat]);
      await order('Spanish Latte', 'Grande', options: <DraftOption>[full]);

      final List<CustomerOrderPattern> patterns = await shop.customers
          .patternsFor(mariaId);
      expect(patterns.length, 2);
      expect(
        await shop.customers.usualFor(mariaId),
        isNull,
        reason: 'neither has repeated yet',
      );
    });

    test('the order options were chosen in does not matter', () async {
      final DraftOption oat = await shop.draftOption('milk', 'Oat');
      final DraftOption vanilla = await shop.draftOption('syrup', 'Vanilla');

      await order(
        'Spanish Latte',
        'Grande',
        options: <DraftOption>[oat, vanilla],
      );
      await order(
        'Spanish Latte',
        'Grande',
        options: <DraftOption>[vanilla, oat],
      );

      final List<CustomerOrderPattern> patterns = await shop.customers
          .patternsFor(mariaId);
      expect(
        patterns.length,
        1,
        reason: 'the same drink must land on the same pattern',
      );
      expect(patterns.single.occurrenceCount, 2);
    });

    test('two of the same drink in one order count as two', () async {
      await order('Spanish Latte', 'Grande', quantity: 2);
      final UsualOrder usual = (await shop.customers.usualFor(mariaId))!;
      expect(usual.pattern.occurrenceCount, 2);
    });

    test('Small and Grande are different usuals', () async {
      await order('Spanish Latte', 'Grande');
      await order('Spanish Latte', 'Small');
      final List<CustomerOrderPattern> patterns = await shop.customers
          .patternsFor(mariaId);
      expect(patterns.length, 2);
    });
  });

  group('a saved usual', () {
    test('beats the calculated one', () async {
      await order('Spanish Latte', 'Grande');
      await order('Spanish Latte', 'Grande');
      await order('Spanish Latte', 'Grande');
      await order('Matcha Oat Latte', 'Grande');
      await order('Matcha Oat Latte', 'Grande');

      // Spanish Latte repeats more, so it is the calculated usual.
      expect(
        (await shop.customers.usualFor(mariaId))!.productName,
        'Spanish Latte',
      );

      final CustomerOrderPattern matcha = (await shop.customers.patternsFor(
        mariaId,
      )).firstWhere((CustomerOrderPattern p) => p.occurrenceCount == 2);
      await shop.customers.saveUsual(customerId: mariaId, patternId: matcha.id);

      final UsualOrder usual = (await shop.customers.usualFor(mariaId))!;
      expect(usual.productName, 'Matcha Oat Latte');
      expect(usual.isSaved, isTrue);
    });

    test('is never overwritten by ordering something else', () async {
      await order('Spanish Latte', 'Grande');
      await order('Spanish Latte', 'Grande');
      final CustomerOrderPattern latte = (await shop.customers.patternsFor(
        mariaId,
      )).single;
      await shop.customers.saveUsual(customerId: mariaId, patternId: latte.id);

      // She orders something different, several times.
      await order('Vietnamese Egg Coffee', 'Grande');
      await order('Vietnamese Egg Coffee', 'Grande');
      await order('Vietnamese Egg Coffee', 'Grande');
      await order('Vietnamese Egg Coffee', 'Grande');

      final UsualOrder usual = (await shop.customers.usualFor(mariaId))!;
      expect(
        usual.productName,
        'Spanish Latte',
        reason: 'a saved usual only changes when she saves a new one',
      );
    });

    test('can be cleared, falling back to what repeats', () async {
      await order('Spanish Latte', 'Grande');
      await order('Spanish Latte', 'Grande');
      await order('Matcha Oat Latte', 'Grande');
      await order('Matcha Oat Latte', 'Grande');
      await order('Matcha Oat Latte', 'Grande');

      final CustomerOrderPattern latte = (await shop.customers.patternsFor(
        mariaId,
      )).firstWhere((CustomerOrderPattern p) => p.occurrenceCount == 2);
      await shop.customers.saveUsual(customerId: mariaId, patternId: latte.id);
      expect(
        (await shop.customers.usualFor(mariaId))!.productName,
        'Spanish Latte',
      );

      await shop.customers.clearUsual(mariaId);
      expect(
        (await shop.customers.usualFor(mariaId))!.productName,
        'Matcha Oat Latte',
      );
    });

    test('cannot be set to another customer\'s order', () async {
      final int otherId = await shop.customers.create(name: 'Mark Reyes');
      await order('Spanish Latte', 'Grande');
      final CustomerOrderPattern mariasPattern =
          (await shop.customers.patternsFor(mariaId)).single;

      await expectLater(
        shop.customers.saveUsual(
          customerId: otherId,
          patternId: mariasPattern.id,
        ),
        throwsA(anything),
      );
    });
  });

  group('the usual is priced at today\'s prices', () {
    test('a price change is reflected next time it is offered', () async {
      await order('Spanish Latte', 'Grande');
      await order('Spanish Latte', 'Grande');
      expect((await shop.customers.usualFor(mariaId))!.price, Money.of(139));

      final Product latte = await shop.product('Spanish Latte');
      await shop.menu.setProductSize(
        productId: latte.id,
        sizeId: (await shop.size('Spanish Latte', 'Grande')).size.id,
        priceCentavos: 14900,
        isAvailable: true,
        isDefaultSize: true,
      );

      expect((await shop.customers.usualFor(mariaId))!.price, Money.of(149));
    });
  });

  group('customer search', () {
    test('finds by part of a name, case-insensitively', () async {
      await shop.customers.create(name: 'Mark Reyes', mobile: '0918 333 3077');
      expect(
        (await shop.customers.search('mar')).map((Customer c) => c.name),
        containsAll(<String>['Maria Santos', 'Mark Reyes']),
      );
      expect((await shop.customers.search('REYES')).single.name, 'Mark Reyes');
    });

    test('finds by mobile, however it was typed', () async {
      await shop.customers.create(name: 'Mark Reyes', mobile: '0918 333 3077');
      expect((await shop.customers.search('3077')).single.name, 'Mark Reyes');
      expect(
        (await shop.customers.search('0918 333')).single.name,
        'Mark Reyes',
      );
      expect(
        (await shop.customers.search('09183333077')).single.name,
        'Mark Reyes',
      );
    });

    test('an empty search shows recent visitors', () async {
      await order('Spanish Latte', 'Grande');
      final List<Customer> recent = await shop.customers.search('');
      expect(recent.first.name, 'Maria Santos');
    });

    test('a name with a wildcard character in it is not a wildcard', () async {
      await shop.customers.create(name: '100% Coffee Guy');
      final List<Customer> results = await shop.customers.search('100%');
      expect(results.single.name, '100% Coffee Guy');
    });
  });
}
