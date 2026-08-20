import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/providers.dart';
import 'package:kubo_pos/app/responsive/form_factor.dart';
import 'package:kubo_pos/app/theme/app_theme.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/features/pos/presentation/pos_screen.dart';

import '../support/test_database.dart';

/// iPhone 16 Plus and both iPad orientations, in logical pixels.
const Size iPhone16Plus = Size(430, 932);
const Size iPadPortrait = Size(834, 1194);
const Size iPadLandscape = Size(1366, 1024);

/// Advances the widget under test past its database reads.
///
/// Two things make `pumpAndSettle` the wrong tool here. The screens show an
/// indeterminate progress indicator while their queries run, which animates
/// forever; and those queries are genuinely asynchronous, so the fake clock a
/// widget test runs on will never let them finish. Alternating a slice of real
/// time with a frame gives the futures a chance to complete and the sheet
/// transitions a chance to finish.
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

  Future<void> pumpPos(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          databaseProvider.overrideWithValue(database),
          clockProvider.overrideWithValue(testClock()),
          initialSettingsProvider.overrideWithValue(
            BusinessSettings.defaults.copyWith(orderNumberPrefix: 'K'),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const AppLayout(child: Scaffold(body: PosScreen())),
        ),
      ),
    );
    await settle(tester);
  }

  group('iPhone', () {
    testWidgets('shows the real menu, with prices', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPhone16Plus);

      expect(find.text('CLASSICS'), findsOneWidget);
      expect(find.text('SPECIALTY COFFEE'), findsOneWidget);
      expect(find.text('BLACK'), findsOneWidget);
      expect(find.text('SPANISH LATTE'), findsOneWidget);
      // Grande 139, Small 129 — a drink with two prices shows the lower one.
      expect(find.text('₱129.00'), findsWidgets);
    });

    testWidgets('the payment block is pinned inside the thumb arc', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPhone16Plus);
      final Offset complete = tester.getCenter(find.text('Add a drink first.'));
      expect(complete.dy, greaterThan(iPhone16Plus.height * 0.75));
    });

    testWidgets('the complete button says what is missing, and is disabled', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPhone16Plus);
      final FilledButton button = tester.widget<FilledButton>(
        find.byType(FilledButton).last,
      );
      expect(button.onPressed, isNull);
      expect(find.text('Add a drink first.'), findsOneWidget);
    });

    testWidgets('switching category swaps the drinks shown', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPhone16Plus);
      expect(find.text('VIETNAMESE COFFEE'), findsNothing);

      await tester.tap(find.text('SPECIALTY COFFEE'));
      await settle(tester);

      expect(find.text('VIETNAMESE COFFEE'), findsOneWidget);
      expect(find.text('VIETNAMESE EGG COFFEE'), findsOneWidget);
      expect(find.text('BLACK'), findsNothing);
    });

    testWidgets('a drink can be added and paid for in a handful of taps', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPhone16Plus);

      // Tap the drink → the configuration sheet opens on its defaults.
      await tester.tap(find.text('SPANISH LATTE'));
      await settle(tester);
      expect(find.text('SIZE'), findsOneWidget);
      expect(find.text('MILK'), findsOneWidget);

      // Ice, sweetness, syrup, sauce and extras are folded away, because the
      // owner said she does not want to be asked.
      expect(find.text('ICE'), findsNothing);
      expect(find.textContaining('More options'), findsOneWidget);

      await tester.tap(find.textContaining('ADD TO ORDER'));
      await settle(tester);

      // Default size is Grande at ₱139.
      expect(find.text('₱139.00'), findsWidgets);
      expect(find.textContaining('1 drink'), findsOneWidget);

      await tester.tap(find.text('CASH'));
      await settle(tester);

      final FilledButton complete = tester.widget<FilledButton>(
        find.byType(FilledButton).last,
      );
      expect(complete.onPressed, isNotNull);
      expect(find.text('COMPLETE ORDER'), findsOneWidget);
    });

    testWidgets('GCash leaves the order incomplete until it is confirmed', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPhone16Plus);

      await tester.tap(find.text('BLACK'));
      await settle(tester);
      await tester.tap(find.textContaining('ADD TO ORDER'));
      await settle(tester);

      await tester.tap(find.text('GCASH'));
      await settle(tester);

      expect(find.text('Confirm the GCash payment arrived.'), findsOneWidget);
      final FilledButton blocked = tester.widget<FilledButton>(
        find.byType(FilledButton).last,
      );
      expect(blocked.onPressed, isNull);

      await tester.tap(find.byType(Checkbox));
      await settle(tester);

      expect(find.text('COMPLETE ORDER'), findsOneWidget);
    });

    testWidgets('choosing a milk adds its charge to the price', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPhone16Plus);

      await tester.tap(find.text('SPANISH LATTE'));
      await settle(tester);
      expect(find.textContaining('ADD TO ORDER · ₱139.00'), findsOneWidget);

      await tester.tap(find.text('Oat'));
      await settle(tester);
      expect(find.textContaining('ADD TO ORDER · ₱159.00'), findsOneWidget);
    });

    testWidgets('milks the shop does not stock are not offered', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPhone16Plus);
      await tester.tap(find.text('SPANISH LATTE'));
      await settle(tester);

      expect(find.text('Full Cream'), findsOneWidget);
      expect(find.text('Oat'), findsOneWidget);
      expect(find.text('Low Fat'), findsNothing);
      expect(find.text('Skimmed'), findsNothing);
      expect(find.text('Coconut'), findsNothing);
    });

    testWidgets('Black offers no milk at all', (WidgetTester tester) async {
      await pumpPos(tester, iPhone16Plus);
      await tester.tap(find.text('BLACK'));
      await settle(tester);

      expect(find.text('SIZE'), findsOneWidget);
      expect(find.text('MILK'), findsNothing);
    });
  });

  group('iPad', () {
    testWidgets('landscape shows three panes with the order always visible', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPadLandscape);

      expect(find.text('CURRENT ORDER'), findsOneWidget);
      expect(find.text('CONFIGURE'), findsOneWidget);
      expect(find.byType(VerticalDivider), findsNWidgets(2));
    });

    testWidgets('landscape configures in place, without a sheet', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPadLandscape);

      await tester.tap(find.text('MATCHA LATTE'));
      await settle(tester);

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('SIZE'), findsOneWidget);
      expect(find.text('MATCHA LATTE'), findsWidgets);
    });

    testWidgets('portrait drops the configuration pane', (
      WidgetTester tester,
    ) async {
      await pumpPos(tester, iPadPortrait);

      expect(find.text('CURRENT ORDER'), findsOneWidget);
      expect(find.text('CONFIGURE'), findsNothing);
      expect(find.byType(VerticalDivider), findsOneWidget);
    });
  });

  testWidgets('the same screen serves every form factor without error', (
    WidgetTester tester,
  ) async {
    for (final Size size in <Size>[iPhone16Plus, iPadPortrait, iPadLandscape]) {
      await pumpPos(tester, size);
      expect(find.byType(PosScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('every amount is in pesos, never a dollar sign', (
    WidgetTester tester,
  ) async {
    await pumpPos(tester, iPhone16Plus);
    expect(find.textContaining('₱'), findsWidgets);
    expect(find.textContaining(r'$'), findsNothing);
  });
}
