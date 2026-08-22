import 'package:flutter/material.dart';

import '../brand/kubo_roof_path.dart';

/// The nipa hut roof from the Kubo Cà Phê logo.
///
/// The outline is her own brush artwork, traced to vector (see
/// [kuboRoofPathData]) rather than bundled as a bitmap: it takes the ink colour
/// of whatever surface it sits on and stays sharp at any size and any screen
/// density, from a 20pt header to a 1024px app icon.
class KuboMark extends StatelessWidget {
  const KuboMark({this.size = 24, this.color, super.key});

  /// Height of the mark. Its width follows the logo's own proportions.
  final double size;

  /// Defaults to the surface's own ink colour.
  final Color? color;

  /// Width the mark occupies at a given [size].
  static double widthFor(double size) =>
      size * (kuboRoofWidth / kuboRoofHeight);

  @override
  Widget build(BuildContext context) {
    final Color ink = color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: widthFor(size),
      height: size,
      // The mark reads as decoration beside the shop's name; the name carries
      // the meaning, so the drawing stays out of the accessibility tree rather
      // than announcing itself twice.
      child: CustomPaint(painter: _RoofPainter(ink)),
    );
  }
}

class _RoofPainter extends CustomPainter {
  const _RoofPainter(this.color);

  final Color color;

  /// Parsing 11 KB of outline data on every repaint would be wasteful, and the
  /// shape never changes — only its colour and scale do.
  static final Path _outline = KuboRoofPath.parse(kuboRoofPathData);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / kuboRoofWidth, size.height / kuboRoofHeight);
    canvas.drawPath(
      _outline,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
    canvas.restore();
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
        KuboMark(size: 20, color: theme.colorScheme.onSurface),
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
