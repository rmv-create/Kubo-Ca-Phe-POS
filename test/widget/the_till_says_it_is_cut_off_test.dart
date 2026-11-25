import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/providers.dart';
import 'package:kubo_pos/app/responsive/form_factor.dart';
import 'package:kubo_pos/app/theme/app_theme.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/domain/entities/app_user.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/features/pos/presentation/pos_screen.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../support/test_database.dart';

/// The till says, to whoever is standing at it, that its orders are going
/// nowhere.
///
/// This has to work for the barista, and the barista cannot open the
/// management area at all — that is the owner's, behind her PIN. He reached
/// the sync screen only because her account was signed in on his phone. So
/// the one place that must carry this is the till itself, which is the one
/// screen he always has.
Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;

  setUp(() async => database = await openSeededDatabase());
  tearDown(() async => database.close());

  Future<void> pumpTill(
    WidgetTester tester, {
    required SyncStanding standing,
    UserRole role = UserRole.barista,
    String till = 'barista',
  }) async {
    // What this phone was set up as, which decides which way back in it is
    // offered. It is not the same thing as who is signed in at the till:
    // the barista's phone was set up with the owner's own account, so it
    // calls itself her phone and he has to say otherwise.
    // Through runAsync: a widget test runs in a zone where real work —
    // the database lives in another isolate — never finishes unless it is
    // let out. Awaited plainly, this line waits for ever.
    await tester.runAsync(
      () => database.db.insert('app_settings', <String, Object?>{
        'key': SettingKeys.syncRole,
        'value': till,
        'updated_at': '2026-11-24T00:00:00.000Z',
      }, conflictAlgorithm: ConflictAlgorithm.replace),
    );

    tester.view.physicalSize =
        const Size(430, 1400) * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(database),
        clockProvider.overrideWithValue(testClock()),
        initialSettingsProvider.overrideWithValue(BusinessSettings.defaults),
        syncStandingProvider.overrideWith((Ref ref) async => standing),
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
          home: const AppLayout(child: Scaffold(body: PosScreen())),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('the barista is told, on the till, with a way out', (
    WidgetTester tester,
  ) async {
    await pumpTill(
      tester,
      standing: SyncStanding(
        paired: true,
        waiting: 357,
        problem: 'This till has not been let into the shop yet.',
        lastAt: DateTime(2026, 11, 20),
      ),
    );

    expect(find.text('The other phone is not getting these orders'), findsOne);
    expect(find.textContaining('357'), findsOne);

    // And the way out opens from the till, not from the owner's side of the
    // app, because he cannot reach that.
    await tester.tap(find.textContaining('357'));
    await settle(tester);
    // The sheet does not guess. It asks, and his way in is one of two
    // buttons rather than a line of small print under a form he cannot use.
    expect(find.text('This phone is cut off from the shop'), findsOne);
    await tester.tap(find.text('THIS IS THE BARISTA\u2019S PHONE'));
    await settle(tester);
    expect(find.text('Let this phone back in'), findsOne);
  });

  testWidgets('the till repeats what the shop actually said', (
    WidgetTester tester,
  ) async {
    // Three people and a photograph were guessing at this for two days.
    await pumpTill(
      tester,
      standing: SyncStanding(
        paired: true,
        waiting: 357,
        problem: 'This till has not been let into the shop yet.',
        lastAt: DateTime(2026, 11, 20),
      ),
    );

    expect(
      find.text('This till has not been let into the shop yet.'),
      findsOne,
    );
  });

  testWidgets('a phone set up with her account still asks whose it is', (
    WidgetTester tester,
  ) async {
    // This phone was set up by signing in with her account, so it calls
    // itself the owner's — and it is the barista who serves on it. Taking
    // the phone's word for that is what kept him locked out.
    await pumpTill(
      tester,
      till: 'owner',
      standing: SyncStanding(
        paired: true,
        waiting: 357,
        problem: 'This till has not been let into the shop yet.',
        lastAt: DateTime(2026, 11, 20),
      ),
    );

    await tester.tap(find.textContaining('357'));
    await settle(tester);

    expect(find.text('I AM THE OWNER'), findsOne);
    expect(find.text('THIS IS THE BARISTA\u2019S PHONE'), findsOne);
    await tester.tap(find.text('I AM THE OWNER'));
    await settle(tester);
    expect(find.text('Sign this phone back in'), findsOne);
  });

  testWidgets('a phone shut out before it sold anything is told too', (
    WidgetTester tester,
  ) async {
    await pumpTill(
      tester,
      standing: const SyncStanding(
        paired: true,
        waiting: 0,
        problem: 'This till has not been let into the shop yet.',
      ),
    );

    expect(find.text('This phone is not reaching the other one'), findsOne);
  });

  testWidgets('a till that is syncing says nothing at all', (
    WidgetTester tester,
  ) async {
    await pumpTill(
      tester,
      standing: SyncStanding(paired: true, waiting: 2, lastAt: DateTime.now()),
    );

    expect(find.textContaining('not getting these orders'), findsNothing);
    expect(find.textContaining('not reaching'), findsNothing);
  });

  testWidgets('nor does a shop with one phone in it', (
    WidgetTester tester,
  ) async {
    await pumpTill(
      tester,
      standing: const SyncStanding(paired: false, waiting: 0),
    );

    expect(find.textContaining('not getting these orders'), findsNothing);
  });
}
