import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/errors/app_exception.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/repositories/payment_method_repository_impl.dart';
import 'package:kubo_pos/domain/entities/app_user.dart';
import 'package:kubo_pos/domain/entities/customer.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';
import 'package:kubo_pos/domain/services/sign_in_service.dart';

import '../support/pos_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late SignInService signIn;
  late PaymentMethodRepositoryImpl methods;

  setUp(() async {
    shop = await PosFixture.open();
    signIn = SignInService(database: shop.db, clock: shop.clock);
    methods = PaymentMethodRepositoryImpl(shop.db, shop.clock);
  });
  tearDown(() async => shop.close());

  group('payment methods', () {
    test('the two the app ships with are there and offered', () async {
      final List<PaymentMethod> all = await methods.all();

      expect(all.map((PaymentMethod m) => m.code), <String>['cash', 'gcash']);
      expect(all.first.takesTendered, isTrue, reason: 'cash counts change');
      expect(
        all.last.needsConfirmation,
        isTrue,
        reason: 'GCash lands where the POS cannot see it',
      );
    });

    test('the owner can add one, and the POS then offers it', () async {
      await methods.add(
        const PaymentMethod(code: '', label: 'Maya', needsConfirmation: true),
      );

      final List<PaymentMethod> all = await methods.all();
      expect(all.map((PaymentMethod m) => m.label), contains('Maya'));
      expect(
        all.firstWhere((PaymentMethod m) => m.label == 'Maya').code,
        'maya',
      );
    });

    test(
      'a retired method disappears from the POS but not from history',
      () async {
        await shop.sell(
          OrderDraft(
            items: <DraftItem>[await shop.item('Black', 'Grande')],
            paymentMethod: PaymentMethod.gcash,
            paymentConfirmed: true,
          ),
        );

        await methods.update(PaymentMethod.gcash.copyWith(isActive: false));

        expect((await methods.all()).map((PaymentMethod m) => m.code), <String>[
          'cash',
        ]);
        expect(
          (await methods.all(includeInactive: true)).length,
          2,
          reason: 'still there, just not offered',
        );
      },
    );

    test('a method that has taken money cannot be deleted', () async {
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      await expectLater(
        methods.delete('cash'),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('one that never took money can be deleted outright', () async {
      await methods.add(const PaymentMethod(code: '', label: 'Bank transfer'));
      await methods.delete('bank_transfer');

      expect(
        (await methods.all(
          includeInactive: true,
        )).map((PaymentMethod m) => m.code),
        <String>['cash', 'gcash'],
      );
    });

    test(
      'the same name twice is refused rather than silently merged',
      () async {
        await expectLater(
          methods.add(const PaymentMethod(code: '', label: 'Cash')),
          throwsA(isA<BusinessRuleException>()),
        );
      },
    );

    test('a receipt keeps the name the button had on the day', () async {
      final CompletedOrder done = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.gcash,
          paymentConfirmed: true,
        ),
      );

      await methods.update(PaymentMethod.gcash.copyWith(label: 'GCash (shop)'));

      final OrderRecord order = (await shop.sales.orderById(done.id))!;
      expect(order.paymentMethod?.label, 'GCash');
    });
  });

  group('signing in', () {
    test('nobody set up means the app is open, and says so', () async {
      expect(await signIn.hasAnyUser(), isFalse);
    });

    test('the right PIN gets in, the wrong one does not', () async {
      final AppUser owner = await signIn.addUser(
        name: 'Owner',
        role: UserRole.owner,
        pin: '1234',
      );

      expect(await signIn.signIn(userId: owner.id, pin: '1234'), isNotNull);
      expect(await signIn.signIn(userId: owner.id, pin: '4321'), isNull);
    });

    test('the PIN is not readable in the database', () async {
      await signIn.addUser(name: 'Owner', role: UserRole.owner, pin: '1234');

      final Map<String, Object?> row = (await shop.db.db.query(
        'app_users',
      )).single;
      expect(row['pin_hash'], isNot(contains('1234')));
      expect(row['pin_salt'], isNotNull);
      // Two people with the same PIN must not produce the same hash.
      await signIn.addUser(
        name: 'Barista',
        role: UserRole.barista,
        pin: '1234',
      );
      final List<Map<String, Object?>> both = await shop.db.db.query(
        'app_users',
      );
      expect(both.first['pin_hash'], isNot(both.last['pin_hash']));
    });

    test('a barista may not manage, an owner may', () async {
      final AppUser owner = await signIn.addUser(
        name: 'Owner',
        role: UserRole.owner,
        pin: '1234',
      );
      final AppUser barista = await signIn.addUser(
        name: 'Barista',
        role: UserRole.barista,
        pin: '5678',
      );

      expect(owner.canManage, isTrue);
      expect(barista.canManage, isFalse);
    });

    test('a PIN that is too short, or not digits, is refused', () async {
      await expectLater(
        signIn.addUser(name: 'A', role: UserRole.owner, pin: '12'),
        throwsA(isA<BusinessRuleException>()),
      );
      await expectLater(
        signIn.addUser(name: 'B', role: UserRole.owner, pin: 'abcd'),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('the last owner cannot switch themselves off', () async {
      final AppUser owner = await signIn.addUser(
        name: 'Owner',
        role: UserRole.owner,
        pin: '1234',
      );

      await expectLater(
        signIn.setActive(userId: owner.id, isActive: false),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('a switched-off person cannot sign in', () async {
      await signIn.addUser(name: 'Owner', role: UserRole.owner, pin: '1111');
      final AppUser barista = await signIn.addUser(
        name: 'Barista',
        role: UserRole.barista,
        pin: '5678',
      );
      await signIn.setActive(userId: barista.id, isActive: false);

      expect(await signIn.signIn(userId: barista.id, pin: '5678'), isNull);
    });
  });

  group('naming an order afterwards', () {
    test('the visit, the spend and the usual all count', () async {
      final CompletedOrder done = await shop.sell(
        OrderDraft(
          items: <DraftItem>[
            await shop.item(
              'Spanish Latte',
              'Grande',
              options: <DraftOption>[await shop.draftOption('milk', 'Oat')],
            ),
          ],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      final int customerId = await shop.customers.create(name: 'Ana');

      await shop.sales.attachCustomer(orderId: done.id, customerId: customerId);

      final Customer ana = (await shop.customers.byId(customerId))!;
      expect(ana.orderCount, 1);
      expect(ana.visitCount, 1);
      expect(ana.totalSpend, Money.of(159));

      // And the drink counts towards their usual, exactly as it would have if
      // they had given their name at the counter. One order is not yet a
      // usual — that takes repetition — but the pattern is on the board.
      final List<CustomerOrderPattern> patterns = await shop.customers
          .patternsFor(customerId);
      expect(patterns, hasLength(1));
      expect(patterns.single.occurrenceCount, 1);
    });

    test('two orders named afterwards add up to a usual', () async {
      final int customerId = await shop.customers.create(name: 'Ana');
      for (int i = 0; i < 2; i++) {
        final CompletedOrder done = await shop.sell(
          OrderDraft(
            items: <DraftItem>[
              await shop.item(
                'Spanish Latte',
                'Grande',
                options: <DraftOption>[await shop.draftOption('milk', 'Oat')],
              ),
            ],
            paymentMethod: PaymentMethod.cash,
          ),
        );
        await shop.sales.attachCustomer(
          orderId: done.id,
          customerId: customerId,
        );
      }

      final UsualOrder? usual = await shop.customers.usualFor(customerId);
      expect(usual, isNotNull);
      expect(usual!.productName, 'Spanish Latte');
      expect(usual.optionNames, contains('Oat'));
    });

    test(
      'the visit is dated when they bought it, not when they gave a name',
      () async {
        final CompletedOrder done = await shop.sell(
          OrderDraft(
            items: <DraftItem>[await shop.item('Black', 'Grande')],
            paymentMethod: PaymentMethod.cash,
          ),
        );
        final int customerId = await shop.customers.create(name: 'Ana');
        await shop.sales.attachCustomer(
          orderId: done.id,
          customerId: customerId,
        );

        final Customer ana = (await shop.customers.byId(customerId))!;
        expect(ana.lastVisitAt, isNotNull);
        expect(
          ana.lastVisitAt!.toUtc().millisecondsSinceEpoch,
          done.createdAt.toUtc().millisecondsSinceEpoch,
        );
      },
    );

    test('an order already under someone is never moved', () async {
      final int first = await shop.customers.create(name: 'Ana');
      final int second = await shop.customers.create(name: 'Ben');
      final CompletedOrder done = await shop.sell(
        OrderDraft(
          customer: (await shop.customers.byId(first))!,
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );

      await expectLater(
        shop.sales.attachCustomer(orderId: done.id, customerId: second),
        throwsA(isA<BusinessRuleException>()),
      );
    });

    test('the order itself now carries the name, for the receipt', () async {
      final CompletedOrder done = await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Black', 'Grande')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      final int customerId = await shop.customers.create(name: 'Ana');
      await shop.sales.attachCustomer(orderId: done.id, customerId: customerId);

      final OrderRecord order = (await shop.sales.orderById(done.id))!;
      expect(order.customerName, 'Ana');
      expect(order.customerId, customerId);
    });
  });
}
