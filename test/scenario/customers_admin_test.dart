import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/ingredient.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// Keeping the customer list usable: adding somebody by hand, telling two
/// people with the same name apart, and taking one off the list.
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

  group('two people called James', () {
    test('are allowed when the note tells them apart', () async {
      await shop.customers.create(name: 'James', notes: 'Office');
      await shop.customers.create(name: 'James', notes: 'Classmate');

      final List<Customer> found = await shop.customers.search('James');
      expect(found.length, 2);
      expect(found.map((Customer c) => c.notes).toSet(), <String>{
        'Office',
        'Classmate',
      });
    });

    test('are refused when neither has a note', () async {
      await shop.customers.create(name: 'James');
      expect(
        () => shop.customers.create(name: 'James'),
        throwsA(
          isA<ValidationException>().having(
            (ValidationException e) => e.message,
            'message',
            contains('Add a note'),
          ),
        ),
      );
    });

    test('are refused when the notes are the same', () async {
      await shop.customers.create(name: 'James', notes: 'Office');
      expect(
        () => shop.customers.create(name: 'James', notes: 'office'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('the check ignores case and stray spaces in the name', () async {
      await shop.customers.create(name: 'James');
      expect(
        () => shop.customers.create(name: '  james '),
        throwsA(isA<ValidationException>()),
      );
    });

    test('renaming onto a taken name is refused too', () async {
      await shop.customers.create(name: 'James', notes: 'Office');
      final int id = await shop.customers.create(name: 'Jamie');
      final Customer jamie = (await shop.customers.byId(id))!;

      expect(
        () => shop.customers.update(
          jamie.copyWith(name: 'James', notes: 'Office'),
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('but saving somebody over themselves is fine', () async {
      final int id = await shop.customers.create(
        name: 'James',
        notes: 'Office',
      );
      final Customer james = (await shop.customers.byId(id))!;
      await shop.customers.update(james.copyWith(mobile: '0917 111 1111'));
      expect((await shop.customers.byId(id))!.mobile, '0917 111 1111');
    });
  });

  group('archiving', () {
    test('takes them off the list without losing the money', () async {
      final int id = await shop.customers.create(name: 'Tita Baby');
      await shop.sell(
        OrderDraft(
          customer: (await shop.customers.byId(id))!,
          items: <DraftItem>[await shop.item('Iced Black', 'Large')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      await shop.customers.archive(id);

      expect(await shop.customers.search('Tita'), isEmpty);
      expect((await shop.customers.archived()).single.name, 'Tita Baby');
      // The sale is untouched.
      expect(
        (await shop.sales.orders(customerId: id)).single.customerName,
        'Tita Baby',
      );
    });

    test('and putting them back brings them home', () async {
      final int id = await shop.customers.create(name: 'Tita Baby');
      await shop.customers.archive(id);
      await shop.customers.restore(id);

      expect((await shop.customers.search('Tita')).single.name, 'Tita Baby');
      expect(await shop.customers.archived(), isEmpty);
    });

    test('an archived name still blocks a duplicate, and says so', () async {
      final int id = await shop.customers.create(name: 'James');
      await shop.customers.archive(id);

      expect(
        () => shop.customers.create(name: 'James'),
        throwsA(
          isA<ValidationException>().having(
            (ValidationException e) => e.message,
            'message',
            contains('archived'),
          ),
        ),
      );
    });
  });

  group('deleting', () {
    test('forgets the person and keeps the sale', () async {
      final int id = await shop.customers.create(name: 'Walk-in');
      final CompletedOrder order = await shop.sell(
        OrderDraft(
          customer: (await shop.customers.byId(id))!,
          items: <DraftItem>[await shop.item('Iced Black', 'Large')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      await shop.customers.delete(id);

      expect(await shop.customers.byId(id), isNull);
      // The money came in either way.
      final OrderRecord kept = (await shop.sales.orderById(order.id))!;
      expect(kept.total, Money.of(129));
      expect(kept.customerId, isNull, reason: 'it is nobody\'s now');
    });

    test('deleting somebody who is gone says so', () async {
      expect(
        () => shop.customers.delete(9999),
        throwsA(isA<NotFoundException>()),
      );
    });
  });

  group('the note', () {
    test('is kept with the customer', () async {
      final int id = await shop.customers.create(
        name: 'James',
        notes: '  Office  ',
      );
      expect((await shop.customers.byId(id))!.notes, 'Office');
    });

    test('an empty note is no note at all', () async {
      final int id = await shop.customers.create(name: 'James', notes: '   ');
      expect((await shop.customers.byId(id))!.notes, isNull);
    });
  });
}
