import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/cloud/shop_directory.dart';
import 'package:kubo_pos/data/db/database_archive.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/data/db/sync/cloud_sync_service.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/data/db/sync/sync_transport.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// A till the shop stopped recognising, and what happens when it is let
/// back in.
///
/// This is what her sister's shop was actually doing. A till is admitted by
/// its own sign-in id, and that id lives in the browser's storage; clear the
/// site data or reinstall from the home screen and the phone goes on taking
/// orders while the shop no longer knows it. Three hundred and fifty-seven
/// changes had piled up on the barista's phone and not one had ever left,
/// so the owner's phone showed three of the day's eight orders.
///
/// The two questions she asked, answered here rather than promised: does
/// letting it back in throw away what it is holding, and does the other
/// phone then get it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture barista;
  late PosFixture owner;
  late _Postbox postbox;
  late _Postbox herPostbox;
  late CloudSyncService hisSync;
  late CloudSyncService herSync;

  setUp(() async {
    barista = await PosFixture.open(separate: true);
    owner = await PosFixture.open(separate: true);
    await PantrySeeder(barista.db, barista.clock).seedIfEmpty();
    await PantrySeeder(owner.db, owner.clock).seedIfEmpty();
    // The same shop on both phones, as pairing leaves them.
    await DatabaseArchive(
      owner.db.db,
      owner.clock,
    ).restore(await DatabaseArchive(barista.db.db, barista.clock).export());
    await owner.db.db.delete('sync_outbox');

    final _Log log = _Log();
    postbox = _Postbox(log);
    herPostbox = _Postbox(log);
    final String shop = ShopDirectory.newShopId();
    hisSync = CloudSyncService(
      engine: SyncEngine(database: barista.db, clock: barista.clock),
      settings: SettingsRepositoryImpl(barista.db, barista.clock),
      clock: barista.clock,
      transport: postbox,
    );
    herSync = CloudSyncService(
      engine: SyncEngine(database: owner.db, clock: owner.clock),
      settings: SettingsRepositoryImpl(owner.db, owner.clock),
      clock: owner.clock,
      transport: herPostbox,
    );
    await hisSync.rememberShop(shop);
    await herSync.rememberShop(shop);
  });
  tearDown(() async {
    await barista.close();
    await owner.close();
  });

  Future<void> heSells(String drink) async => barista.sell(
    OrderDraft(
      items: <DraftItem>[await barista.item(drink, 'Large')],
      paymentMethod: PaymentMethod.cash,
    ),
  );

  test(
    'a till the shop does not recognise keeps everything it takes',
    () async {
      postbox.letIn = false;

      for (final String drink in <String>['Spanish Latte', 'Iced Black']) {
        await heSells(drink);
      }
      final SyncReport refused = await hisSync.syncNow();

      expect(refused.ok, isFalse);
      // Says what the phone knows: it is signed in and the shop would not
      // take its orders. Whether the shop still holds a record of it is
      // not something the phone can see, and claiming otherwise sent
      // everybody chasing invites for a till that was admitted all along.
      expect(refused.error, contains('would not take its orders'));
      expect(postbox.posted, isEmpty, reason: 'nothing could go out');
      expect(
        await hisSync.waitingToGoUp(),
        greaterThan(0),
        reason: 'and so it is still waiting, not thrown away',
      );
    },
  );

  test('letting it back in sends the lot, and she gets it', () async {
    postbox.letIn = false;
    for (final String drink in <String>[
      'Spanish Latte',
      'Iced Black',
      'Ca Phe Trung',
    ]) {
      await heSells(drink);
    }
    await hisSync.syncNow();
    final int waiting = await hisSync.waitingToGoUp();
    expect(waiting, greaterThan(0));

    // The owner reads out an invite and he types it in. Nothing about the
    // phone's own records changes — this is only the shop agreeing to
    // listen again.
    postbox.letIn = true;

    final SyncReport now = await hisSync.syncNow();
    expect(now.ok, isTrue);
    // Every queued row goes in one round. Fewer changes than rows, because
    // several edits to one row travel as the row's last word.
    expect(now.sent, greaterThan(0));
    expect(now.sent, lessThanOrEqualTo(waiting));
    expect(await hisSync.waitingToGoUp(), 0);

    // His three orders are still his three orders.
    expect((await barista.sales.orders()).length, 3);

    // And her phone, which had none of them, now has all three.
    await herSync.syncNow();
    final List<OrderRecord> hers = await owner.sales.orders();
    expect(hers, hasLength(3));
    expect(
      hers.map((OrderRecord o) => o.lines.single.productName).toSet(),
      <String>{'Spanish Latte', 'Iced Black', 'Ca Phe Trung'},
    );
  });

  test('what she sold while he was cut off reaches him too', () async {
    postbox.letIn = false;
    await heSells('Spanish Latte');
    await hisSync.syncNow();

    // She has been selling all along, and her phone was never shut out.
    await owner.sell(
      OrderDraft(
        items: <DraftItem>[await owner.item('Matcha Oat Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    await herSync.syncNow();

    postbox.letIn = true;
    final SyncReport back = await hisSync.syncNow();
    expect(back.ok, isTrue);

    expect(
      (await barista.sales.orders()).map(
        (OrderRecord o) => o.lines.single.productName,
      ),
      containsAll(<String>['Spanish Latte', 'Matcha Oat Latte']),
    );
  });
}

/// The shop's log, which both phones read and write.
class _Log {
  final List<SyncChange> posted = <SyncChange>[];
}

/// One phone's way into the log — and the shop's right to refuse it.
///
/// Per phone, because that is the shape of the real failure: the owner's
/// till was admitted all along, and only the barista's had stopped being
/// recognised. A postbox that refused both would have hidden exactly the
/// thing this is for.
class _Postbox implements SyncTransport {
  _Postbox(this._log);

  final _Log _log;
  bool letIn = true;

  /// The sign-in id this phone is holding. A phone whose browser loses the
  /// anonymous session comes back holding a different one, and the shop
  /// admitted the old one.
  String? uid = 'till-uid';

  @override
  String? get identity => uid;

  List<SyncChange> get posted => _log.posted;

  @override
  Future<bool> isReady() async => letIn;

  @override
  Future<void> publish(List<SyncChange> changes) async {
    if (!letIn) throw Exception('refused');
    _log.posted.addAll(changes);
  }

  @override
  Future<SyncFetch> fetch({String? afterCursor, int limit = 500}) async {
    final int from = int.tryParse(afterCursor ?? '0') ?? 0;
    return SyncFetch(
      changes: _log.posted.skip(from).toList(),
      cursor: '${_log.posted.length}',
    );
  }

  @override
  Future<void> heartbeat({required String label}) async {}
}
