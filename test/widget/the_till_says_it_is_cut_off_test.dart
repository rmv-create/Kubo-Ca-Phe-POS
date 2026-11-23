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
  }) async {
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
    expect(find.text('Let this phone back in'), findsOne);
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
