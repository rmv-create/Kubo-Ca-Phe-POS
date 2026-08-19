import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/responsive/form_factor.dart';
import 'package:kubo_pos/app/theme/app_theme.dart';
import 'package:kubo_pos/features/pos/presentation/pos_screen.dart';

/// iPhone 16 Plus and the two iPad orientations, in logical pixels.
const Size iPhone16Plus = Size(430, 932);
const Size iPadPortrait = Size(834, 1194);
const Size iPadLandscape = Size(1366, 1024);

Future<void> _pumpPos(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  tester.view.devicePixelRatio = tester.view.devicePixelRatio;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light,
        home: const AppLayout(child: Scaffold(body: PosScreen())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('iPhone: one column, payment pinned at the bottom', (
    WidgetTester tester,
  ) async {
    await _pumpPos(tester, iPhone16Plus);

    expect(find.text('COMPLETE ORDER'), findsOneWidget);
    expect(find.text('Cash'), findsOneWidget);
    expect(find.text('GCash'), findsOneWidget);
    // No side pane on a phone: the order lives in the bottom bar.
    expect(find.text('Current order'.toUpperCase()), findsNothing);

    final Offset complete = tester.getCenter(find.text('COMPLETE ORDER'));
    expect(
      complete.dy,
      greaterThan(iPhone16Plus.height * 0.75),
      reason: 'the primary action must sit inside the thumb arc',
    );
  });

  testWidgets('iPhone: the complete button is a large touch target', (
    WidgetTester tester,
  ) async {
    await _pumpPos(tester, iPhone16Plus);
    final Size button = tester.getSize(find.byType(FilledButton));
    expect(button.height, greaterThanOrEqualTo(56));
  });

  testWidgets('iPad landscape: three panes, order always visible', (
    WidgetTester tester,
  ) async {
    await _pumpPos(tester, iPadLandscape);

    expect(find.text('CURRENT ORDER'), findsOneWidget);
    expect(find.text('CONFIGURE'), findsOneWidget);
    expect(find.text('COMPLETE ORDER'), findsOneWidget);
    expect(find.byType(VerticalDivider), findsNWidgets(2));
  });

  testWidgets('iPad portrait: two panes, no separate configuration column', (
    WidgetTester tester,
  ) async {
    await _pumpPos(tester, iPadPortrait);

    expect(find.text('CURRENT ORDER'), findsOneWidget);
    expect(find.text('CONFIGURE'), findsNothing);
    expect(find.byType(VerticalDivider), findsOneWidget);
  });

  testWidgets('the same screen serves every form factor', (
    WidgetTester tester,
  ) async {
    for (final Size size in <Size>[iPhone16Plus, iPadPortrait, iPadLandscape]) {
      await _pumpPos(tester, size);
      expect(find.byType(PosScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('every amount on screen is shown in pesos', (
    WidgetTester tester,
  ) async {
    await _pumpPos(tester, iPhone16Plus);
    expect(find.text('₱0.00'), findsOneWidget);
    expect(find.textContaining(r'$'), findsNothing);
  });

  testWidgets('unfinished controls are disabled, not fake', (
    WidgetTester tester,
  ) async {
    await _pumpPos(tester, iPhone16Plus);

    final FilledButton complete = tester.widget<FilledButton>(
      find.byType(FilledButton),
    );
    expect(complete.onPressed, isNull);

    for (final Element element in find.byType(OutlinedButton).evaluate()) {
      expect((element.widget as OutlinedButton).onPressed, isNull);
    }
  });
}
