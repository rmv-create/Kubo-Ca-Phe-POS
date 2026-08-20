import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The nipa hut roof from the Kubo Cà Phê logo.
///
/// Two brush strokes that cross above the apex and sweep out and down, drawn
/// rather than bundled as an image so it takes the ink colour of whatever
/// surface it sits on and stays crisp at any size and any screen density.
class KuboMark extends StatelessWidget {
  const KuboMark({this.size = 24, this.color, super.key});

  /// Height of the mark. Its width is twice this — the roof is wide and low.
  final double size;

  /// Defaults to the surface's own ink colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color ink = color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size * 2,
      height: size,
      child: CustomPaint(
        painter: _RoofPainter(ink),
        // The mark reads as decoration beside the shop's name; the name
        // carries the meaning, so the drawing stays out of the accessibility
        // tree rather than announcing itself twice.
        isComplex: false,
      ),
    );
  }
}

class _RoofPainter extends CustomPainter {
  const _RoofPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Laid out on the logo's own 120 x 60 grid, then scaled.
    final double sx = size.width / 120;
    final double sy = size.height / 60;

    // Thick enough to read as a brush at a glance, thin enough to stay sharp
    // in a 20pt header.
    final double stroke = math.max(1.8, size.height * 0.125);

    final Paint brush = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    // Left stroke: starts low on the left, sweeps up and past the apex.
    final Path left = Path()
      ..moveTo(6 * sx, 55 * sy)
      ..quadraticBezierTo(40 * sx, 34 * sy, 73 * sx, 4 * sy);

    // Right stroke: the mirror, crossing the first near the top.
    final Path right = Path()
      ..moveTo(114 * sx, 55 * sy)
      ..quadraticBezierTo(80 * sx, 34 * sy, 47 * sx, 4 * sy);

    canvas.drawPath(left, brush);
    canvas.drawPath(right, brush);
  }

  @override
  bool shouldRepaint(_RoofPainter oldDelegate) => oldDelegate.color != color;
}

/// The mark with the shop's name beside it, as it appears in the POS header.
class KuboWordmark extends StatelessWidget {
  const KuboWordmark({required this.businessName, this.subtitle, super.key});

  final String businessName;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        KuboMark(size: 22, color: theme.colorScheme.onSurface),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                businessName,
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle != null)
                Text(subtitle!, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}
