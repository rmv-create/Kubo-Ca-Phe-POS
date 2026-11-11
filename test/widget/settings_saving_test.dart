import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/providers.dart';
import 'package:kubo_pos/app/theme/app_theme.dart';
import 'package:kubo_pos/data/db/app_database.dart';
import 'package:kubo_pos/domain/entities/business_settings.dart';
import 'package:kubo_pos/features/settings/presentation/settings_screen.dart';

import '../support/test_database.dart';

/// Typed settings used to save only when she pressed the keyboard's done
/// key. Typing 1111 and tapping away looked as though it had been taken, and
/// the screen then came back saying 1001.
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

  Future<ProviderContainer> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize =
        const Size(430, 932) * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(database),
        clockProvider.overrideWithValue(testClock()),
        initialSettingsProvider.overrideWithValue(
          BusinessSettings.defaults.copyWith(orderNumberStart: 1001),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light, home: const SettingsScreen()),
      ),
    );
    await settle(tester);
    return container;
  }

  int startOf(ProviderContainer c) =>
      c.read(settingsControllerProvider).orderNumberStart;

  testWidgets('a number typed and left behind is still saved', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = await pumpSettings(tester);
    expect(startOf(c), 1001);

    await tester.enterText(find.widgetWithText(TextField, '1001'), '1111');
    // She taps somewhere else rather than pressing done — which is what
    // happens on a phone, where the keyboard has no obvious done key.
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);

    expect(startOf(c), 1111);
  });

  testWidgets('and pressing done still saves it', (WidgetTester tester) async {
    final ProviderContainer c = await pumpSettings(tester);

    await tester.enterText(find.widgetWithText(TextField, '1001'), '1234');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(startOf(c), 1234);
  });

  testWidgets('a number already used is refused, not silently taken', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = await pumpSettings(tester);

    await tester.enterText(find.widgetWithText(TextField, '1001'), '0');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);

    expect(startOf(c), 1001, reason: 'zero is not a number to start at');
  });
}
