import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/shared/brand/kubo_roof_path.dart';

void main() {
  group('KuboRoofPath.parse', () {
    test('reads every command the tracer emits', () {
      final Path path = KuboRoofPath.parse('M0 0L10 0C10 5 5 10 0 10Z');

      expect(path.getBounds(), const Rect.fromLTRB(0, 0, 10, 10));
      expect(path.fillType, PathFillType.evenOdd);
    });

    test(
      'rejects data it does not understand rather than drawing it wrong',
      () {
        // Relative and arc commands would silently produce a different shape.
        expect(() => KuboRoofPath.parse('m0 0l10 10'), throwsFormatException);
        expect(
          () => KuboRoofPath.parse('M0 0A5 5 0 0 1 10 10'),
          throwsFormatException,
        );
        expect(() => KuboRoofPath.parse('M0'), throwsFormatException);
      },
    );
  });

  group('the roof outline', () {
    test('fills the grid it declares', () {
      final Rect bounds = KuboRoofPath.parse(kuboRoofPathData).getBounds();

      // The trace is cropped to the ink, so the outline should reach all four
      // edges of its own coordinate grid. A mark that has drifted inside its
      // box would sit visibly off-centre next to the shop's name.
      expect(bounds.left, lessThan(2));
      expect(bounds.top, lessThan(2));
      expect(bounds.right, closeTo(kuboRoofWidth, 2));
      expect(bounds.bottom, closeTo(kuboRoofHeight, 2));
    });

    test('is a roof: two strokes crossing above a peak', () {
      final Path roof = KuboRoofPath.parse(kuboRoofPathData);

      // The strokes cross a little right of centre, exactly as she painted
      // them. The apex is inked and the room under the roof is not — the one
      // check that tells a nipa hut apart from a smudge.
      expect(roof.contains(const Offset(523, 100)), isTrue);
      expect(roof.contains(const Offset(523, 400)), isFalse);

      // Two eaves, falling away either side towards the bottom corners.
      expect(roof.contains(const Offset(280, 300)), isTrue);
      expect(roof.contains(const Offset(700, 300)), isTrue);
      expect(roof.contains(const Offset(500, 300)), isFalse);

      // Wide and low, the logo's own proportions.
      final Rect bounds = roof.getBounds();
      expect(bounds.width / bounds.height, closeTo(2.16, 0.1));
    });
  });
}
