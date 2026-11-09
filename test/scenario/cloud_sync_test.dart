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

/// The errand: say what we did, hear what they did, remember where we got
/// to — and never let a bad signal stop the shop from selling coffee.
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

  Future<void> sellOne() async => shop.sell(
    OrderDraft(
      items: <DraftItem>[await shop.item('Spanish Latte', 'Large')],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  group('a round of syncing', () {
    test('what this till did goes up', () async {
      await sellOne();

      final SyncReport report = await sync.syncNow();

      expect(report.ok, isTrue);
      expect(report.sent, greaterThan(0));
      expect(postbox.posted.map((SyncChange c) => c.table), contains('orders'));
    });

    test('nothing goes up twice', () async {
      await sellOne();
      await sync.syncNow();
      final int first = postbox.posted.length;

      final SyncReport again = await sync.syncNow();

      expect(again.sent, 0);
      expect(postbox.posted, hasLength(first));
      expect(again.describe(), 'Up to date');
    });

    test('where we got to is remembered, so nothing is read twice', () async {
      await sync.syncNow();

      expect(await settings.readRaw(SettingKeys.syncCursor), postbox.cursor);
    });

    test('a till that was never paired does nothing at all', () async {
      await settings.writeRaw(SettingKeys.syncShopId, '');

      final SyncReport report = await sync.syncNow();

      expect(report.isPaired, isFalse);
      expect(postbox.posted, isEmpty);
      expect(report.describe(), contains('Not connected'));
    });
  });

  group('when the signal is bad', () {
    test('the round fails quietly and says so in plain words', () async {
      await sellOne();
      postbox.failWith = Exception('unavailable: network is down');

      final SyncReport report = await sync.syncNow();

      expect(report.ok, isFalse);
      expect(report.describe(), contains('Nothing is lost'));
      expect(await sync.lastError(), isNotNull);
    });

    test('what did not go up is still waiting afterwards', () async {
      await sellOne();
      final int waiting = await sync.waitingToGoUp();
      postbox.failWith = Exception('unavailable');

      await sync.syncNow();

      expect(await sync.waitingToGoUp(), waiting);
    });

    test('and goes up on the next round', () async {
      await sellOne();
      postbox.failWith = Exception('unavailable');
      await sync.syncNow();

      postbox.failWith = null;
      final SyncReport report = await sync.syncNow();

      expect(report.ok, isTrue);
      expect(report.sent, greaterThan(0));
      expect(await sync.lastError(), isNull, reason: 'the trouble has passed');
    });

    test('a till that has not been let in is told so, not shown a stack '
        'trace', () async {
      postbox.failWith = Exception(
        '[cloud_firestore/permission-denied] Missing or insufficient '
        'permissions.',
      );

      final SyncReport report = await sync.syncNow();

      expect(
        report.describe(),
        'This till has not been let into the shop yet.',
      );
    });

    test('the cursor does not move when the round failed', () async {
      await sync.syncNow();
      final String? got = await settings.readRaw(SettingKeys.syncCursor);
      postbox.failWith = Exception('unavailable');

      await sync.syncNow();

      expect(await settings.readRaw(SettingKeys.syncCursor), got);
    });
  });

  group('the shop and the invite', () {
    test('the shop is named once and keeps its name', () async {
      await sync.rememberShop(ShopDirectory.newShopId());
      final String? first = await sync.shopId();
      await sync.rememberShop(first!);

      expect(await sync.shopId(), first);
      expect(first.length, 32, reason: 'long enough not to be guessed at');
    });

    test('an invite avoids the letters people mishear', () {
      for (int i = 0; i < 100; i++) {
        final String invite = ShopDirectory.newInvite();
        expect(invite, matches(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$')));
        expect(
          invite,
          isNot(matches(RegExp('[OI015S]'))),
          reason: 'read aloud across a counter',
        );
      }
    });

    test('two invites in a row are not the same', () {
      final Set<String> codes = <String>{
        for (int i = 0; i < 20; i++) ShopDirectory.newInvite(),
      };
      expect(codes.length, 20);
    });

    test('an invite is read back however she types it', () {
      expect(ShopDirectory.tidy('k7pq-m39x'), 'K7PQM39X');
      expect(ShopDirectory.tidy('K7PQ M39X'), 'K7PQM39X');
      expect(ShopDirectory.tidy('  K7PQ-M39X  '), 'K7PQM39X');
    });
  });
}

/// A postbox on the table rather than in the cloud.
class _Postbox implements SyncTransport {
  final List<SyncChange> posted = <SyncChange>[];
  final List<SyncChange> waiting = <SyncChange>[];
  Exception? failWith;
  String cursor = '0';

  void _check() {
    final Exception? failure = failWith;
    if (failure != null) throw failure;
  }

  @override
  Future<bool> isReady() async {
    _check();
    return true;
  }

  @override
  Future<void> publish(List<SyncChange> changes) async {
    _check();
    posted.addAll(changes);
  }

  @override
  Future<SyncFetch> fetch({String? afterCursor, int limit = 500}) async {
    _check();
    cursor = '${int.parse(cursor) + 1}';
    return SyncFetch(changes: List<SyncChange>.of(waiting), cursor: cursor);
  }

  @override
  Future<void> heartbeat({required String label}) async => _check();
}
