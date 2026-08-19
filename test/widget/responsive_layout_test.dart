import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/app/responsive/form_factor.dart';

void main() {
  group('breakpoints', () {
    test('iPhone widths are compact', () {
      // iPhone 16 Plus is 430pt; the smallest current iPhone is 375pt.
      expect(KuboBreakpoints.fromWidth(375), FormFactor.compact);
      expect(KuboBreakpoints.fromWidth(430), FormFactor.compact);
      expect(KuboBreakpoints.fromWidth(599), FormFactor.compact);
    });

    test('iPad portrait is medium', () {
      expect(KuboBreakpoints.fromWidth(768), FormFactor.medium);
      expect(KuboBreakpoints.fromWidth(834), FormFactor.medium);
      expect(KuboBreakpoints.fromWidth(899), FormFactor.medium);
    });

    test('iPad landscape is expanded', () {
      expect(KuboBreakpoints.fromWidth(1024), FormFactor.expanded);
      expect(KuboBreakpoints.fromWidth(1366), FormFactor.expanded);
    });

    test(
      'a narrow iPad split view gets the phone layout, which is correct',
      () {
        expect(KuboBreakpoints.fromWidth(507), FormFactor.compact);
      },
    );

    test('only the wider layouts get a persistent order pane', () {
      expect(FormFactor.compact.hasSideOrderPane, isFalse);
      expect(FormFactor.medium.hasSideOrderPane, isTrue);
      expect(FormFactor.expanded.hasSideOrderPane, isTrue);
    });
  });

  group('ResponsiveBuilder', () {
    Future<void> pumpAt(WidgetTester tester, double width) async {
      // The surface itself has to change size: a SizedBox inside a fixed test
      // window is clamped by the window, so it would never report a wide
      // layout.
      tester.view.physicalSize =
          Size(width, 900) * tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: AppLayout(
            child: ResponsiveBuilder(
              compact: _label,
              medium: _mediumLabel,
              expanded: _expandedLabel,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('picks the builder for the width it is given', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, 430);
      expect(find.text('compact'), findsOneWidget);

      await pumpAt(tester, 834);
      expect(find.text('medium'), findsOneWidget);

      await pumpAt(tester, 1366);
      expect(find.text('expanded'), findsOneWidget);
    });

    testWidgets('falls back to the next smaller layout when one is missing', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize =
          const Size(1366, 1024) * tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: AppLayout(child: ResponsiveBuilder(compact: _label)),
        ),
      );
      await tester.pump();
      expect(find.text('compact'), findsOneWidget);
    });
  });
}

Widget _label(BuildContext context) => const Text('compact');
Widget _mediumLabel(BuildContext context) => const Text('medium');
Widget _expandedLabel(BuildContext context) => const Text('expanded');
