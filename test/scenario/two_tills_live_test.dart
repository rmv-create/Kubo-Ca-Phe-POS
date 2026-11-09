import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/core/money/money.dart';
import 'package:kubo_pos/data/db/sync/cloud_sync_service.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/data/db/sync/sync_transport.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';

import '../support/pos_fixture.dart';
import '../support/test_database.dart';

/// Two phones, one shop — the whole errand, not just the merge.
///
/// The merge itself is proved elsewhere. What this is about is the part
/// that was missing: that a till joining an established shop ends up
/// holding the shop, and that the two stay level afterwards without
/// anybody pressing anything.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture hers;
  late PosFixture barista;
  late _Postbox postbox;
  late CloudSyncService hersSync;
  late CloudSyncService baristaSync;

  setUp(() async {
    hers = await PosFixture.open(separate: true);
    // The barista's phone starts empty: no menu, no prices, nothing. That
    // is the real starting state, and the reason a first pull exists.
    barista = await PosFixture.openBlank(separate: true);
    postbox = _Postbox();

    final SyncEngine hersEngine = SyncEngine(
      database: hers.db,
      clock: hers.clock,
    );
    final SyncEngine baristaEngine = SyncEngine(
      database: barista.db,
      clock: barista.clock,
    );

    hersSync = CloudSyncService(
      engine: hersEngine,
      settings: SettingsRepositoryImpl(hers.db, hers.clock),
      clock: hers.clock,
      transport: postbox.forTill(await hersEngine.deviceId()),
    );
    baristaSync = CloudSyncService(
      engine: baristaEngine,
      settings: SettingsRepositoryImpl(barista.db, barista.clock),
      clock: barista.clock,
      transport: postbox.forTill(await baristaEngine.deviceId()),
    );
    await hersSync.rememberShop('her-shop');
    await baristaSync.rememberShop('her-shop');
  });

  tearDown(() async {
    await hers.close();
    await barista.close();
  });

  Future<int> drinksOn(PosFixture till) async => till.countOf('products');

  test('a joining till ends up holding the whole shop', () async {
    // Everything she has already set up has to reach the new phone, not
    // just whatever changes from now on.
    await SyncEngine(
      database: hers.db,
      clock: hers.clock,
    ).enqueueEverything();

    expect(await drinksOn(barista), 0, reason: 'it really does start empty');

    await hersSync.catchUp(label: 'Owner');
    await baristaSync.catchUp(label: 'Barista');

    expect(await drinksOn(barista), await drinksOn(hers));
    expect(
      await barista.countOf('product_sizes'),
      await hers.countOf('product_sizes'),
    );
  });

  test('and at her prices, not at a default', () async {
    await SyncEngine(
      database: hers.db,
      clock: hers.clock,
    ).enqueueEverything();
    await hersSync.catchUp();
    await baristaSync.catchUp();

    final List<Map<String, Object?>> rows = await barista.db.db.rawQuery(
      '''
      SELECT ps.price_centavos AS price
      FROM product_sizes ps
      JOIN products p ON p.id = ps.product_id
      JOIN sizes s ON s.id = ps.size_id
      WHERE p.name = 'Spanish Latte' AND s.name = 'Large'
      ''',
    );
    expect(Money(rows.single['price']! as int), Money.of(139));
  });

  test('an order rung up on one shows up on the other', () async {
    await SyncEngine(
      database: hers.db,
      clock: hers.clock,
    ).enqueueEverything();
    await hersSync.catchUp();
    await baristaSync.catchUp();

    await hers.sell(
      OrderDraft(
        items: <DraftItem>[await hers.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    await hersSync.syncNow();
    await baristaSync.syncNow();

    expect(await barista.countOf('orders'), 1);
    expect(await barista.countOf('payments'), 1);
  });

  test('and the other way round', () async {
    await SyncEngine(
      database: hers.db,
      clock: hers.clock,
    ).enqueueEverything();
    await hersSync.catchUp();
    await baristaSync.catchUp();

    await barista.sell(
      OrderDraft(
        items: <DraftItem>[await barista.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );

    await baristaSync.syncNow();
    await hersSync.syncNow();

    expect(await hers.countOf('orders'), 1);
  });

  test('catching up stops when there is nothing left, rather than spinning',
      () async {
    await SyncEngine(
      database: hers.db,
      clock: hers.clock,
    ).enqueueEverything();
    await hersSync.catchUp();
    await baristaSync.catchUp();

    final int before = postbox.fetches;
    await baristaSync.catchUp();
    expect(
      postbox.fetches - before,
      lessThanOrEqualTo(2),
      reason: 'level already: one look, not two hundred',
    );
  });

  test('a till with no signal sells anyway, and catches up after', () async {
    await SyncEngine(
      database: hers.db,
      clock: hers.clock,
    ).enqueueEverything();
    await hersSync.catchUp();
    await baristaSync.catchUp();

    postbox.down = true;
    await barista.sell(
      OrderDraft(
        items: <DraftItem>[await barista.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    final SyncReport failed = await baristaSync.syncNow();
    expect(failed.error, isNotNull);
    expect(await barista.countOf('orders'), 1, reason: 'the sale stands');

    postbox.down = false;
    await baristaSync.syncNow();
    await hersSync.syncNow();
    expect(await hers.countOf('orders'), 1, reason: 'and arrives later');
  });
}

/// One postbox, two tills, no network.
class _Postbox {
  final List<SyncChange> posted = <SyncChange>[];
  bool down = false;
  int fetches = 0;

  /// Each till by the engine's own name for it, so the postbox can keep
  /// a till from hearing its own changes back.
  SyncTransport forTill(String deviceId) => _Till(this, deviceId);
}

class _Till implements SyncTransport {
  _Till(this._box, this._deviceId);

  final _Postbox _box;
  final String _deviceId;

  @override
  Future<bool> isReady() async => !_box.down;

  @override
  Future<void> publish(List<SyncChange> changes) async {
    if (_box.down) throw Exception('unavailable');
    _box.posted.addAll(changes);
  }

  @override
  Future<SyncFetch> fetch({String? afterCursor, int limit = 500}) async {
    if (_box.down) throw Exception('unavailable');
    _box.fetches++;
    final int from = int.tryParse(afterCursor ?? '0') ?? 0;
    final List<SyncChange> mine = <SyncChange>[];
    int at = from;
    while (at < _box.posted.length && mine.length < limit) {
      final SyncChange change = _box.posted[at];
      at++;
      if (change.deviceId == _deviceId) continue;
      mine.add(change);
    }
    return SyncFetch(changes: mine, cursor: '$at');
  }

  @override
  Future<void> heartbeat({required String label}) async {}
}
