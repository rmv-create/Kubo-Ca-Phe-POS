import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/cloud/shop_directory.dart';
import 'package:kubo_pos/data/db/sync/cloud_sync_service.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/data/db/sync/sync_transport.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';

import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';

/// Why a till is being kept out, in its own words.
///
/// Three quite different things were all reported as "this till has not
/// been let into the shop yet". Only one of them is answered by another
/// invite, and the shop spent days making invites against the other two.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture shop;
  late _Postbox postbox;
  late CloudSyncService sync;
  late SettingsRepositoryImpl settings;

  setUp(() async {
    shop = await PosFixture.open(separate: true);
    settings = SettingsRepositoryImpl(shop.db, shop.clock);
    postbox = _Postbox();
    sync = CloudSyncService(
      engine: SyncEngine(database: shop.db, clock: shop.clock),
      settings: settings,
      clock: shop.clock,
      transport: postbox,
    );
    await sync.rememberShop(ShopDirectory.newShopId());
  });
  tearDown(() async => shop.close());

  Future<String?> complaint() async => (await sync.syncNow()).error;

  test('a phone that has never been let in is told so', () async {
    postbox.ready = false;

    expect(await complaint(), contains('not been let into the shop yet'));
  });

  test('a phone holding no sign-in is told to restart', () async {
    postbox
      ..ready = false
      ..uid = null;

    expect(await complaint(), contains('Close the app and open it again'));
  });

  test(
    'a phone whose sign-in has changed is told that, not to try a code',
    () async {
      // It joined as one id and came back holding another: the browser threw
      // the anonymous session away. The shop admitted the old id, so every
      // invite after this is refused, for ever, for a reason no code touches.
      await settings.writeRaw(SettingKeys.syncTillUid, 'the-one-let-in');
      postbox
        ..ready = false
        ..uid = 'a-different-one';

      final String? said = await complaint();
      expect(said, contains('sign-in has changed'));
      expect(said, contains('needs a fresh invite'));
      expect(said, contains('the-one'), reason: 'both ids, to compare by eye');
      expect(said, contains('a-differ'));
    },
  );

  group('refused at the post box, with a sign-in in hand', () {
    // His screen, exactly: a queue waiting, signed in, and told only that
    // the shop would not take the orders.
    setUp(() async {
      await shop.sell(
        OrderDraft(
          items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
          paymentMethod: PaymentMethod.cash,
        ),
      );
      postbox.refuseThePost = true;
    });

    test('a phone never admitted says so, and shows the id it holds', () async {
      final String? said = await complaint();
      expect(said, contains('not been let into the shop yet'));
      expect(said, contains('the-one-'), reason: 'the id it is signed in as');
    });

    test('a phone whose sign-in changed says that, here too', () async {
      await settings.writeRaw(SettingKeys.syncTillUid, 'the-one-let-in');
      postbox.uid = 'a-different-one';

      final String? said = await complaint();
      expect(said, contains('sign-in has changed'));
      expect(said, contains('needs a fresh invite'));
    });

    test('and the shop refusing an admitted phone is named as that', () async {
      await settings.writeRaw(SettingKeys.syncTillUid, 'the-one-let-in');

      final String? said = await complaint();
      expect(said, contains('even though it was let in'));
      expect(said, contains('a new one will not help'));
    });
  });

  test(
    'a phone the shop simply refuses is not sent for another code',
    () async {
      await settings.writeRaw(SettingKeys.syncTillUid, 'the-one-let-in');
      postbox
        ..ready = false
        ..uid = 'the-one-let-in';

      final String? said = await complaint();
      expect(said, contains('even though it was let in'));
      expect(said, contains('a new one will not help'));
    },
  );
}

class _Postbox implements SyncTransport {
  bool ready = true;
  String? uid = 'the-one-let-in';

  /// A phone signed in to *something* gets past the readiness check and is
  /// refused at the post box instead. That is what his was doing, and the
  /// message there used to explain nothing.
  bool refuseThePost = false;

  @override
  String? get identity => uid;

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<void> publish(List<SyncChange> changes) async {
    if (refuseThePost) {
      throw Exception(
        '[cloud_firestore/permission-denied] Missing or insufficient '
        'permissions.',
      );
    }
  }

  @override
  Future<SyncFetch> fetch({String? afterCursor, int limit = 500}) async =>
      const SyncFetch.nothing('0');

  @override
  Future<void> heartbeat({required String label}) async {}
}
