import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/cloud/account_service.dart';
import 'package:kubo_pos/data/cloud/shop_directory.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/services/shop_access_service.dart';

import '../support/pos_fixture.dart';

/// Whether a till is the owner's or the barista's, which decides the only
/// way it can get back into the shop.
///
/// Getting this wrong cost the shop a day. A phone that has lost its place
/// is put back two different ways, and only one works for each:
///
///  * the **barista's** phone is admitted by an invite the owner reads out;
///  * the **owner's** phone signs in with the account that owns the shop.
///
/// Offering her an invite is worse than useless: she would be inviting
/// herself to her own shop, and she cannot make an invite at all while she
/// is signed out — which is the very state that put the question on her
/// screen. She was asked for eight characters she had no way to get, and
/// the code she made for the barista before that could not have worked
/// either.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late SettingsRepositoryImpl settings;

  setUp(() async {
    shop = await PosFixture.open();
    settings = SettingsRepositoryImpl(shop.db, shop.clock);
  });
  tearDown(() async => shop.close());

  // The cloud pieces are built but never reached: asking a till what it is
  // is a question about this phone's own notes.
  ShopAccessService access() => ShopAccessService(
    database: shop.db,
    settings: settings,
    clock: shop.clock,
    account: AccountService(),
    directory: ShopDirectory(),
    engine: SyncEngine(database: shop.db, clock: shop.clock),
  );

  test('a till set up by the owner is hers', () async {
    await settings.writeRaw(SettingKeys.syncRole, 'owner');

    expect(await access().isOwner, isTrue);
  });

  test('a till let in with an invite is the barista\'s', () async {
    await settings.writeRaw(SettingKeys.syncRole, 'barista');

    expect(await access().isOwner, isFalse);
  });

  test('a phone that has never been told is treated as hers', () async {
    // The safer way round for this one question: she is offered a sign-in,
    // which is hers to use and which a barista simply cannot complete,
    // rather than an invite she has no way to make.
    expect(await access().isOwner, isTrue);
  });
}
