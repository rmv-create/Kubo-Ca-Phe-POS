import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/providers.dart';
import 'package:kubo_pos/data/db/seed/pantry_seeder.dart';
import 'package:kubo_pos/data/db/sync/sync_change.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/domain/entities/app_user.dart';
import 'package:kubo_pos/domain/entities/order_draft.dart';
import 'package:kubo_pos/domain/entities/reporting.dart';

import '../support/pos_fixture.dart';

/// What the owner's phone does when the barista's phone has been busy.
///
/// Her complaint, in her own words: the barista is on 1217 and she is still
/// on 1216. The order had reached her phone — a round had written it into
/// her database — but every list in the app refreshes when *this* phone does
/// something, and a round is the one moment something happens that this
/// phone did not do. So the screen went on showing what it had read before.
///
/// The same silence kept the barista from being given anything: a right she
/// granted travelled to his phone and sat in his database, unread, because
/// the settings in front of him were the ones loaded when the app started.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosFixture her;
  late PosFixture till;
  late SyncEngine hers;
  late SyncEngine theirs;
  late ProviderContainer herPhone;

  setUp(() async {
    her = await PosFixture.open(separate: true);
    till = await PosFixture.open(separate: true);
    await PantrySeeder(her.db, her.clock).seedIfEmpty();
    await PantrySeeder(till.db, till.clock).seedIfEmpty();
    hers = SyncEngine(database: her.db, clock: her.clock);
    theirs = SyncEngine(database: till.db, clock: till.clock);

    herPhone = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(her.db),
        clockProvider.overrideWithValue(her.clock),
        initialSettingsProvider.overrideWithValue(her.settings),
      ],
    );
    addTearDown(herPhone.dispose);
  });
  tearDown(() async {
    await her.close();
    await till.close();
  });

  /// One round, in the direction the complaint runs: his phone to hers.
  Future<void> hisNewsReachesHer() async {
    final List<SyncChange> news = await theirs.collect();
    await hers.apply(news);
    await theirs.markSent(news);
  }

  test('the next number follows the other till, once she is told', () async {
    final String before = await herPhone.read(nextOrderNumberProvider.future);

    // He rings one up, and it reaches her database.
    await till.sell(
      OrderDraft(
        items: <DraftItem>[await till.item('Spanish Latte', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    await hisNewsReachesHer();

    // Until something tells the screens, hers is the number it always was —
    // which is the 1216 she was looking at.
    expect(herPhone.read(nextOrderNumberProvider).valueOrNull, before);

    herPhone.read(salesRevisionProvider.notifier).heard();
    final String after = await herPhone.read(nextOrderNumberProvider.future);

    expect(after, isNot(before), reason: 'his order moved the counter on');
  });

  test('his order is on her list once she is told', () async {
    await herPhone.read(ordersProvider(null).future);

    await till.sell(
      OrderDraft(
        items: <DraftItem>[await till.item('Iced Black', 'Large')],
        paymentMethod: PaymentMethod.cash,
      ),
    );
    await hisNewsReachesHer();

    herPhone.read(salesRevisionProvider.notifier).heard();
    final List<OrderRecord> orders = await herPhone.read(
      ordersProvider(null).future,
    );
    expect(orders.map((OrderRecord o) => o.lines.single.productName), <String>[
      'Iced Black',
    ]);
  });

  test('telling the screens does not start another round of telling', () async {
    // The nudge belongs to things this phone did. Hearing the other till out
    // and immediately answering back would have the two of them taking turns
    // to say nothing, every twenty seconds, all day.
    final int before = herPhone.read(salesRevisionProvider);
    herPhone.read(salesRevisionProvider.notifier).heard();

    expect(herPhone.read(salesRevisionProvider), before + 1);
  });

  /// His phone, with him at it.
  ///
  /// Signed in as the barista on purpose: a shop with no PINs set up at all
  /// is deliberately wide open, and would answer yes to everything below
  /// without proving anything.
  ProviderContainer hisPhone({bool mayCorrect = false}) {
    final ProviderContainer phone = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(till.db),
        clockProvider.overrideWithValue(till.clock),
        initialSettingsProvider.overrideWithValue(
          till.settings.copyWith(baristaMayCorrectOrders: mayCorrect),
        ),
      ],
    );
    addTearDown(phone.dispose);
    phone
        .read(signedInUserProvider.notifier)
        .set(
          const AppUser(
            id: 1,
            name: 'Jaja',
            role: UserRole.barista,
            isActive: true,
          ),
        );
    return phone;
  }

  test('a right she grants reaches his phone without a restart', () async {
    final ProviderContainer his = hisPhone();

    expect(his.read(canCorrectOrdersProvider), isFalse);

    // She turns it on, and it travels.
    await her.settingsRepository.save(
      her.settings.copyWith(baristaMayCorrectOrders: true),
    );
    final List<SyncChange> news = await hers.collect();
    await theirs.apply(news);

    // His app is still running, holding the settings it started with.
    expect(his.read(canCorrectOrdersProvider), isFalse);

    await his.read(settingsControllerProvider.notifier).reload();

    expect(
      his.read(canCorrectOrdersProvider),
      isTrue,
      reason: 'she gave it to him; he should not have to restart to have it',
    );
  });

  test('and she can take it back the same way', () async {
    final ProviderContainer his = hisPhone(mayCorrect: true);
    expect(his.read(canCorrectOrdersProvider), isTrue);

    await her.settingsRepository.save(
      her.settings.copyWith(baristaMayCorrectOrders: false),
    );
    final List<SyncChange> news = await hers.collect();
    await theirs.apply(news);
    await his.read(settingsControllerProvider.notifier).reload();

    expect(his.read(canCorrectOrdersProvider), isFalse);
  });
}
