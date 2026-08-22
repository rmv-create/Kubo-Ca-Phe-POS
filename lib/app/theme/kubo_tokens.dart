import 'package:flutter/widgets.dart';

/// Design tokens for Kubo Cà Phê.
///
/// Every colour, size and radius the app draws comes from here. Re-skinning
/// the whole product is a change to this one file, not a hunt through widgets.
///
/// ## The Paper colourway
///
/// White and black, and almost nothing in between. The ground is a paper white
/// with the faintest cool cast, the ink is a true near-black, and the greys
/// between them carry the same cast so the screen reads as one material rather
/// than a stack of unrelated panels. It is the highest-contrast palette of the
/// three that were sampled, which is what a phone propped on a sunny counter
/// needs.
///
/// One colour survives the black and white: [alert]. It is spent on one thing
/// at a time — stock about to run out, or an action that cannot be undone —
/// and never as decoration. Because it is the only hue on screen it does not
/// have to shout to be seen.
abstract final class KuboColors {
  // ── Light: paper ──
  /// The ground the whole app sits on.
  static const Color paper = Color(0xFFF6F6F7);

  /// Cards, sheets and anything that should read as lifted off the ground.
  static const Color paperRaised = Color(0xFFFFFFFF);

  /// Wells: fields, and rows pressed into the ground.
  static const Color paperSunk = Color(0xFFE9EAEC);

  /// Between [paper] and [paperSunk]: filled inputs and unselected chips.
  static const Color paperMuted = Color(0xFFEDEEF0);

  // ── Ink: the brush black of the logo. Type, and actions that commit. ──
  static const Color ink = Color(0xFF0A0A0A);
  static const Color inkMuted = Color(0xFF5B5C60);
  static const Color inkFaint = Color(0xFF8B8C91);
  static const Color hairline = Color(0xFFDCDDE0);
  static const Color hairlineSoft = Color(0xFFE9EAEC);

  // ── Accent: not a colour, a weight. Marks what is chosen. ──
  /// Solid accent — a selected payment method, a committed button.
  static const Color accent = Color(0xFF3C3D40);

  /// The deepest step, one shade off the ink itself.
  static const Color accentDeep = Color(0xFF26272A);

  /// The quiet accent: selection backgrounds that must stay readable.
  static const Color accentSoft = Color(0xFFE4E5E8);

  /// The one hue in the palette. Critical stock, refunds, voids, deletions.
  static const Color alert = Color(0xFFB42318);
  static const Color alertSoft = Color(0xFFFDECEA);

  // ── Dark: evening service. Roles swap, relationships hold. ──
  static const Color darkPaper = Color(0xFF0B0B0C);
  static const Color darkPaperRaised = Color(0xFF17181A);
  static const Color darkPaperSunk = Color(0xFF060607);
  static const Color darkPaperMuted = Color(0xFF1D1E21);
  static const Color darkInk = Color(0xFFFFFFFF);
  static const Color darkInkMuted = Color(0xFFA5A6AB);
  static const Color darkInkFaint = Color(0xFF75767B);
  static const Color darkHairline = Color(0xFF2A2B2E);
  static const Color darkHairlineSoft = Color(0xFF1F2023);
  static const Color darkAccent = Color(0xFF6E7075);
  static const Color darkAccentDeep = Color(0xFF3A3C40);
  static const Color darkAccentSoft = Color(0xFF232427);
  static const Color darkAlert = Color(0xFFFF6B5E);
  static const Color darkAlertSoft = Color(0xFF3A1512);
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
