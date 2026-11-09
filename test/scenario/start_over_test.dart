import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/db/shop_reset.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';
import 'package:kubo_pos/domain/entities/app_user.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/entities/menu.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/services/sign_in_service.dart';

import '../support/pos_fixture.dart';

/// Emptying the shop and setting it up again from scratch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late ShopReset reset;
  late SettingsRepositoryImpl settings;

  setUp(() async {
    shop = await PosFixture.open();
    reset = ShopReset(shop.db, shop.clock);
    settings = SettingsRepositoryImpl(shop.db, shop.clock);
  });
  tearDown(() async => shop.close());

  Future<int> rows(String table) => shop.countOf(table);

  Future<void> tradeABit() async {
    await shop.sell(
      OrderDraft(
        items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    await shop.customers.create(name: 'Tita Baby', mobile: '09175551234');
    await SignInService(
      database: shop.db,
      clock: shop.clock,
    ).addUser(name: 'Ate', role: UserRole.owner, pin: '123456');
  }

  group('what goes', () {
    test('the orders, the customers and the PINs', () async {
      await tradeABit();
      expect(await rows('orders'), 1);

      await reset.run();

      expect(await rows('orders'), 0);
      expect(await rows('order_items'), 0);
      expect(await rows('payments'), 0);
      expect(await rows('customers'), 0);
      expect(await rows('app_users'), 0, reason: 'she sets the PINs again');
      expect(await rows('audit_log'), 0);
    });

    test('settings she changed go back to how they started', () async {
      await settings.writeRaw(SettingKeys.businessName, 'Somewhere Else');
      await reset.run();

      expect(
        await settings.readRaw(SettingKeys.businessName),
        isNot('Somewhere Else'),
      );
    });
  });

  group('what comes back', () {
    test('her menu, at her prices', () async {
      await tradeABit();
      await reset.run();

      expect(await rows('products'), greaterThan(0));
      final ProductSize large = await shop.size('Spanish Latte', 'Large');
      expect(large.price, Money.of(139), reason: 'her card, not a default');
    });

    test('her pantry and her recipes', () async {
      await reset.run();

      expect(await rows('ingredients'), greaterThan(0));
      expect(await rows('recipe_items'), greaterThan(0));
      expect(
        await rows('inventory_movements'),
        greaterThan(0),
        reason: 'opening stock is posted through the ledger',
      );
    });

    test('and the app asks for the PINs again', () async {
      await tradeABit();
      await reset.run();

      expect(
        await SignInService(database: shop.db, clock: shop.clock).hasAnyUser(),
        isFalse,
      );
    });
  });

  group('what is deliberately kept', () {
    test('which shop this phone belongs to, and as what', () async {
      // Without this she would come back as a stranger: a second shop in
      // her Firebase beside the first, and no way to point her account at
      // it, because which shop an account owns is written once.
      await settings.writeRaw(SettingKeys.syncShopId, 'her-shop-id');
      await settings.writeRaw(SettingKeys.syncRole, 'owner');
      await tradeABit();

      await reset.run();

      expect(await settings.readRaw(SettingKeys.syncShopId), 'her-shop-id');
      expect(await settings.readRaw(SettingKeys.syncRole), 'owner');
    });

    test(
      'a phone that never joined a shop keeps nothing, and is fine',
      () async {
        await tradeABit();
        await reset.run();

        expect(
          await settings.readRaw(SettingKeys.syncShopId),
          anyOf(isNull, ''),
        );
      },
    );

    test('the migration ledger, so the schema is not rebuilt', () async {
      final int before = await rows('schema_migrations');
      await reset.run();
      expect(await rows('schema_migrations'), before);
    });
  });

  test('starting over twice is no worse than once', () async {
    await tradeABit();
    await reset.run();
    await reset.run();

    expect(await rows('orders'), 0);
    expect(await rows('products'), greaterThan(0));
    final ProductSize large = await shop.size('Spanish Latte', 'Large');
    expect(large.price, Money.of(139));
  });
}
