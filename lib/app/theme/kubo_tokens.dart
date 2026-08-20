import 'package:flutter/widgets.dart';

/// Design tokens for Kubo Cà Phê.
///
/// Every colour, size and radius the app draws comes from here. Re-skinning
/// the whole product is a change to this one file, not a hunt through widgets.
///
/// The palette is taken directly from the brand: the cream stock behind the
/// logo, the kraft of the menu card, the brush black of the strokes, and the
/// red of the CA PHÊ seal.
abstract final class KuboColors {
  // ── Light: the cream stock the logo is printed on ──
  static const Color paper = Color(0xFFEFE6D6);
  static const Color paperRaised = Color(0xFFF8F2E7);
  static const Color paperSunk = Color(0xFFE3D8C5);

  // ── Kraft: the menu card. Carries the order, never the whole screen. ──
  static const Color kraft = Color(0xFFAC8A5E);
  static const Color kraftDeep = Color(0xFF8E6F47);
  static const Color kraftSoft = Color(0xFFD9C4A3);

  // ── Brush black: the logo strokes. Type and primary actions. ──
  static const Color ink = Color(0xFF201811);
  static const Color inkMuted = Color(0xFF5A4B3D);
  static const Color inkFaint = Color(0xFF8A7A69);
  static const Color hairline = Color(0xFFCDBEA6);
  static const Color hairlineSoft = Color(0xFFDED2BC);

  /// The red of the CA PHÊ seal — the only chromatic accent in the app.
  /// It is spent on one thing at a time: confirm this, or undo this.
  static const Color seal = Color(0xFF9B3B2C);
  static const Color sealSoft = Color(0xFFEBD5CD);

  // ── Dark: evening service. Roles swap, relationships hold. ──
  static const Color darkPaper = Color(0xFF241C15);
  static const Color darkPaperRaised = Color(0xFF2E241B);
  static const Color darkPaperSunk = Color(0xFF1A140F);
  static const Color darkKraft = Color(0xFF7C6142);
  static const Color darkKraftDeep = Color(0xFF5E492F);
  static const Color darkKraftSoft = Color(0xFF3D3021);
  static const Color darkInk = Color(0xFFF2E9DA);
  static const Color darkInkMuted = Color(0xFFBFAE99);
  static const Color darkInkFaint = Color(0xFF90806D);
  static const Color darkHairline = Color(0xFF443729);
  static const Color darkHairlineSoft = Color(0xFF33291E);
  static const Color darkSeal = Color(0xFFD97B66);
  static const Color darkSealSoft = Color(0xFF3A2119);
}

/// A 4pt spacing scale. Touch-first, so the useful values start higher than a
/// desktop app's would.
abstract final class KuboSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;
  static const double xxxl = 40;
}

abstract final class KuboRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 22;
  static const double pill = 999;
}

/// Minimum interactive sizes.
///
/// The owner uses this app one-handed while steaming milk. Apple's 44pt floor
/// is a floor, not a target: the buttons that matter are bigger.
abstract final class KuboTouch {
  static const double minTarget = 48;
  static const double chip = 44;
  static const double productTile = 96;
  static const double payButton = 56;
  static const double primaryAction = 64;
}

/// Named durations, so motion stays consistent and short. Nothing in the order
/// path animates for longer than [quick] — the POS must never make her wait.
abstract final class KuboMotion {
  static const Duration quick = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 200);
  static const Duration sheet = Duration(milliseconds: 260);
}
