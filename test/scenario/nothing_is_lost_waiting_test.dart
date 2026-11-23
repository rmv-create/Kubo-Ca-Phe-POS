import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/cloud/shop_directory.dart';
import 'package:kubo_pos/data/db/sync/cloud_sync_service.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/data/db/sync/sync_transport.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';

import '../support/pos_fixture.dart';

/// What happens to a change that arrives before the row it belongs to.
///
/// The log is read a page at a time, and it is a stream of rows rather than
/// a tree, so a change can easily arrive before the thing it points at: an
/// order's line ahead of its order, a customer's habit ahead of the
/// customer. Such a change cannot be applied yet.
///
/// It used to be held for the length of one round and then forgotten, while
/// the cursor moved on past it for ever. The parent would arrive on the next
/// page and what belonged to it was already gone — an order on one phone
/// that never appeared on the other, no error anywhere, nothing to find.
/// This is the owner looking at eight orders on one phone and three on the
/// other.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an orphan is not lost when the next page carries its parent', () async {
    final PosFixture shop = await PosFixture.open(separate: true);
    addTearDown(shop.close);
    final SettingsRepositoryImpl settings = SettingsRepositoryImpl(
      shop.db,
      shop.clock,
    );
    final _PagedPostbox postbox = _PagedPostbox();
    final CloudSyncService sync = CloudSyncService(
      engine: SyncEngine(database: shop.db, clock: shop.clock),
      settings: settings,
      clock: shop.clock,
      transport: postbox,
    );
    await sync.rememberShop(ShopDirectory.newShopId());

    // Real drinks from this till's own menu, so the only thing the change
    // below is missing is the customer.
    final String productUid =
        (await shop.db.db.query(
              'products',
              columns: <String>['uid'],
              limit: 1,
            )).single['uid']!
            as String;
    final String sizeUid =
        (await shop.db.db.query(
              'sizes',
              columns: <String>['uid'],
              limit: 1,
            )).single['uid']!
            as String;

    // A customer, posted in two pages the wrong way round: the till hears
    // about the customer's note before it hears the customer exists. In the
    // shop this is a page boundary, or a change that overtook another.
    postbox.pages = <List<SyncChange>>[
      <SyncChange>[
        SyncChange(
          changeId: 'other:2',
          deviceId: 'other',
          table: 'customer_order_patterns',
          rowUid: 'pattern-1',
          op: SyncOp.upsert,
          at: '2026-11-23T09:00:01.000Z',
          data: <String, Object?>{
            'customer_id@': 'customer-1',
            'product_id@': productUid,
            'size_id@': sizeUid,
            'signature': 'x',
            'option_ids_json': '[]',
            'occurrence_count': 1,
            'first_ordered_at': '2026-11-23T09:00:01.000Z',
            'last_ordered_at': '2026-11-23T09:00:01.000Z',
          },
        ),
      ],
      <SyncChange>[
        const SyncChange(
          changeId: 'other:1',
          deviceId: 'other',
          table: 'customers',
          rowUid: 'customer-1',
          op: SyncOp.upsert,
          at: '2026-11-23T09:00:00.000Z',
          data: <String, Object?>{
            'name': 'Tita Baby',
            'segment': 'new',
            'is_active': 1,
            'order_count': 0,
            'visit_count': 0,
            'item_count': 0,
            'total_spend_centavos': 0,
            'created_at': '2026-11-23T09:00:00.000Z',
            'updated_at': '2026-11-23T09:00:00.000Z',
          },
        ),
      ],
    ];

    final SyncReport first = await sync.syncNow();
    expect(
      first.applied?.waitingForParent,
      1,
      reason: 'the pattern has nothing to hang on yet',
    );

    expect(
      await shop.db.db.query('sync_waiting'),
      hasLength(1),
      reason: 'written down, not merely held for the length of a round',
    );

    // Second round: the parent arrives.
    final SyncReport second = await sync.syncNow();
    expect(second.error, isNull);
    expect(
      second.applied?.applied,
      2,
      reason: 'the customer, and the thing that had been waiting for her',
    );

    expect(
      await shop.db.db.query('sync_waiting'),
      isEmpty,
      reason: 'nothing is held once it has gone in',
    );
    final List<Map<String, Object?>> customers = await shop.db.db.query(
      'customers',
    );
    final List<Map<String, Object?>> patterns = await shop.db.db.query(
      'customer_order_patterns',
    );
    expect(customers, hasLength(1), reason: 'the customer did arrive');
    expect(
      patterns,
      hasLength(1),
      reason: 'and what belongs to her must not have been thrown away',
    );
  });
}

/// A postbox that hands out one page per round, as Firestore does.
class _PagedPostbox implements SyncTransport {
  List<List<SyncChange>> pages = <List<SyncChange>>[];
  int _round = 0;

  @override
  Future<bool> isReady() async => true;

  @override
  Future<void> publish(List<SyncChange> changes) async {}

  @override
  Future<SyncFetch> fetch({String? afterCursor, int limit = 500}) async {
    if (_round >= pages.length) {
      return SyncFetch.nothing(afterCursor ?? '0');
    }
    final List<SyncChange> page = pages[_round];
    _round++;
    return SyncFetch(changes: page, cursor: '$_round');
  }

  @override
  Future<void> heartbeat({required String label}) async {}
}
