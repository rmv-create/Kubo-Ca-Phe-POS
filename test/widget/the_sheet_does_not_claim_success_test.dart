import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/providers.dart';
import 'package:kubo_pos/app/theme/app_theme.dart';
import 'package:kubo_pos/core/time/clock.dart';
import 'package:kubo_pos/data/cloud/account_service.dart';
import 'package:kubo_pos/data/cloud/shop_directory.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/data/db/sync/cloud_sync_service.dart';
import 'package:kubo_pos/data/db/sync/sync_engine.dart';
import 'package:kubo_pos/data/repositories/settings_repository_impl.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/domain/services/shop_access_service.dart';
import 'package:kubo_pos/features/access/presentation/rejoin_sheet.dart';

import '../support/test_database.dart';

/// What the sheet is allowed to say after a code is typed.
///
/// For days they typed invites, the sheet said "this phone is back in the
/// shop — everything it was holding is on its way to the other phone now",
/// and not one order moved. The sheet was asking the door whether it had
/// opened and never asking the shop whether it would take the orders: the
/// catch-up ran, came back refused, and its answer was thrown away.
///
/// Nobody could tell a join that worked from one that did not, because the
/// app could not tell them apart either.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;

  setUp(() async => database = await openSeededDatabase());
  tearDown(() async => database.close());

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> typeACode(WidgetTester tester, {required bool roundIsOk}) async {
    final Clock clock = testClock();
    final SettingsRepositoryImpl settings = SettingsRepositoryImpl(
      database,
      clock,
    );
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(database),
        clockProvider.overrideWithValue(clock),
        initialSettingsProvider.overrideWithValue(BusinessSettings.defaults),
        shopAccessServiceProvider.overrideWithValue(
          _LetsAnybodyIn(
            database: database,
            settings: settings,
            clock: clock,
            engine: SyncEngine(database: database, clock: clock),
          ),
        ),
        cloudSyncProvider.overrideWith(
          (Ref ref) async => _Rounds(
            ok: roundIsOk,
            engine: SyncEngine(database: database, clock: clock),
            settings: settings,
            clock: clock,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize =
        const Size(430, 2000) * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => RejoinSheet.show(context),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN'));
    await settle(tester);

    await tester.tap(find.text('THIS IS THE BARISTA’S PHONE'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'ABCD1234');
    await tester.tap(find.text('LET IT BACK IN'));
    await settle(tester);
  }

  testWidgets('a refused round is not called getting back in', (
    WidgetTester tester,
  ) async {
    await typeACode(tester, roundIsOk: false);

    expect(find.text('This phone is back in the shop'), findsNothing);
    expect(
      find.textContaining('would not take its orders'),
      findsOne,
      reason: 'the shop refused, and the sheet has to say so',
    );
  });

  testWidgets('a round that went through is', (WidgetTester tester) async {
    await typeACode(tester, roundIsOk: true);

    expect(find.text('This phone is back in the shop'), findsOne);
  });
}

/// A door that always opens.
class _LetsAnybodyIn extends ShopAccessService {
  _LetsAnybodyIn({
    required super.database,
    required super.settings,
    required super.clock,
    required super.engine,
  }) : super(account: AccountService(), directory: ShopDirectory());

  @override
  Future<AccessOutcome> joinWithInvite({
    required String code,
    required String deviceLabel,
  }) async => const AccessOutcome.ok(ShopStanding.inside);

  @override
  Future<String> deviceLabel() async => 'Jaja';
}

/// A shop that takes the orders, or does not.
class _Rounds extends CloudSyncService {
  _Rounds({
    required this.ok,
    required super.engine,
    required super.settings,
    required super.clock,
  });

  final bool ok;

  @override
  Future<SyncReport> catchUp({
    String label = 'Till',
    int rounds = 200,
    void Function(int applied)? onProgress,
  }) async => ok
      ? const SyncReport(sent: 1540, applied: null)
      : const SyncReport.failed(
          'This phone is signed in (a1b2c3d4…) and the shop would not take '
          'its orders.',
        );
}
