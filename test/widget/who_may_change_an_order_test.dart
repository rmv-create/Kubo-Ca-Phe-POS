import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/providers.dart';
import 'package:kubo_pos/app/responsive/form_factor.dart';
import 'package:kubo_pos/app/theme/app_theme.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/domain/entities/app_user.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/features/pos/presentation/pos_screen.dart';
import 'package:kubo_pos/features/sales/presentation/orders_screen.dart';

import '../support/pos_fixture.dart';

/// Who may do what to a finished order.
///
/// Her sister will not always be in the shop, and the person at the till is
/// the one standing in front of the customer who has changed their mind. So
/// the barista can be given leave to correct an order — and nothing else.
/// Voiding, refunding, deleting and moving it to another day stay the
/// owner's, and he asks for those with her PIN.
///
/// These are the doors, checked from the outside.
Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late int orderId;

  setUp(() async {
    shop = await PosFixture.open();
    await PantrySeeder(shop.db, shop.clock).seedIfEmpty();
    final CompletedOrder sold = await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    orderId = sold.id;
  });
  tearDown(() async => shop.close());

  Future<ProviderContainer> open(
    WidgetTester tester, {
    required UserRole role,
    required bool mayCorrect,
  }) async {
    // A phone's width, and tall enough that the whole sheet is built: a
    // lazy list does not build what is below the fold, and these tests are
    // about which tiles exist at all.
    tester.view.physicalSize =
        const Size(430, 2600) * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(shop.db),
        clockProvider.overrideWithValue(shop.clock),
        initialSettingsProvider.overrideWithValue(
          BusinessSettings.defaults.copyWith(
            baristaMayCorrectOrders: mayCorrect,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(signedInUserProvider.notifier)
        .set(AppUser(id: 1, name: 'Jaja', role: role, isActive: true));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: OrderDetailScreen(orderId: orderId),
        ),
      ),
    );
    await settle(tester);
    return container;
  }

  testWidgets('the owner may do everything to it', (WidgetTester tester) async {
    await open(tester, role: UserRole.owner, mayCorrect: false);

    expect(find.text('Change this order'), findsOne);
    expect(find.text('Change the date'), findsOne);
    expect(find.text('Void'), findsOne);
    expect(find.text('Delete this order'), findsOne);
  });

  testWidgets('and sees what the drink cost her to make', (
    WidgetTester tester,
  ) async {
    await open(tester, role: UserRole.owner, mayCorrect: false);
    expect(find.text('Cost to make'), findsOne);
    expect(find.text('Gross profit'), findsOne);
  });

  testWidgets('the barista cannot correct it until she says so', (
    WidgetTester tester,
  ) async {
    await open(tester, role: UserRole.barista, mayCorrect: false);
    expect(find.text('Change this order'), findsNothing);
  });

  testWidgets('once she has, he can — and that is the only door that opens', (
    WidgetTester tester,
  ) async {
    await open(tester, role: UserRole.barista, mayCorrect: true);

    expect(find.text('Change this order'), findsOne);

    // The rest are still on the screen, because he is allowed to ask for
    // them. Tapping one asks for her, not for nothing.
    await tester.tap(find.text('Void'));
    await settle(tester);
    expect(find.text('This one is the owner’s'), findsOne);
    expect(find.textContaining('type her PIN'), findsOne);
  });

  testWidgets('what it cost to make is never his business', (
    WidgetTester tester,
  ) async {
    await open(tester, role: UserRole.barista, mayCorrect: true);
    expect(find.text('Cost to make'), findsNothing);
    expect(find.text('Gross profit'), findsNothing);
  });

  testWidgets('and he is given a way to the orders at the till', (
    WidgetTester tester,
  ) async {
    // What he reported: no order list. The orders live behind Management,
    // which is hers, so being allowed to correct an order is no use without
    // a door to walk through — this is that door, on the POS header.
    tester.view.physicalSize =
        const Size(430, 932) * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);

    Future<void> pumpTill({required bool mayCorrect}) async {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          databaseProvider.overrideWithValue(shop.db),
          clockProvider.overrideWithValue(shop.clock),
          initialSettingsProvider.overrideWithValue(
            BusinessSettings.defaults.copyWith(
              baristaMayCorrectOrders: mayCorrect,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(signedInUserProvider.notifier)
          .set(
            const AppUser(
              id: 1,
              name: 'Jaja',
              role: UserRole.barista,
              isActive: true,
            ),
          );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const AppLayout(child: Scaffold(body: PosScreen())),
          ),
        ),
      );
      await settle(tester);
    }

    await pumpTill(mayCorrect: false);
    expect(find.byTooltip('Orders'), findsNothing);

    await pumpTill(mayCorrect: true);
    expect(find.byTooltip('Orders'), findsOne);
  });

  // Whether her PIN is the right PIN is tested without a screen, in
  // test/scenario/the_leave_she_gives_test.dart: typing six digits into a
  // sheet and waiting for the answer is a slow way to ask a question the
  // service answers directly.
}
