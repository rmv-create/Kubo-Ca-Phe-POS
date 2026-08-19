import 'package:flutter/widgets.dart';

/// Design tokens for Kubo Cà Phê.
///
/// Every colour, size and radius the app draws comes from here. Re-skinning
/// the whole product — to match a signboard, a menu card, a photo of the shop
/// — is a change to this one file, not a hunt through widgets.
///
/// The palette is warm and earthy, taken from the name itself: *kubo* (the
/// nipa hut — bamboo, thatch, sunlight) and *cà phê* (roasted bean, condensed
/// milk, crema).
abstract final class KuboColors {
  // Core browns — roast levels, darkest to lightest.
  static const Color espresso = Color(0xFF2A1A12);
  static const Color roast = Color(0xFF4A3122);
  static const Color bark = Color(0xFF6B4B33);
  static const Color crema = Color(0xFFC9A882);
  static const Color oatMilk = Color(0xFFF2E6D6);
  static const Color condensedMilk = Color(0xFFFBF5EC);

  // Accents.
  static const Color turmeric = Color(0xFFD98E32); // selected / highlight
  static const Color turmericSoft = Color(0xFFF7E3C6);
  static const Color pandan = Color(0xFF3F7D5B); // confirmed / paid
  static const Color pandanSoft = Color(0xFFDDEDE3);
  static const Color chili = Color(0xFFB03A2E); // critical
  static const Color chiliSoft = Color(0xFFF7E0DD);
  static const Color amber = Color(0xFFB77A05); // low stock warning
  static const Color amberSoft = Color(0xFFFAEBCD);

  // Neutrals for text and lines on the light surface.
  static const Color ink = Color(0xFF241812);
  static const Color inkMuted = Color(0xFF7A6857);
  static const Color inkFaint = Color(0xFFA8988A);
  static const Color hairline = Color(0xFFE4D7C6);

  // Dark-theme surfaces (evening service, low light).
  static const Color darkSurface = Color(0xFF1B120D);
  static const Color darkSurfaceRaised = Color(0xFF261A13);
  static const Color darkHairline = Color(0xFF3B2A1E);
  static const Color darkInk = Color(0xFFF3E8DA);
  static const Color darkInkMuted = Color(0xFFB9A691);
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
