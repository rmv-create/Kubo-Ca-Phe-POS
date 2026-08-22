import 'package:flutter/material.dart';

import 'kubo_tokens.dart';

/// Builds the light and dark Material themes from [KuboColors].
///
/// The type ramp uses the platform font (SF Pro on iOS/iPadOS) rather than a
/// bundled family: it renders crisply at every Dynamic Type size and keeps the
/// app feeling native.
abstract final class AppTheme {
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;

    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      // Primary is the brush black of the logo: buttons that commit, and type.
      primary: isDark ? KuboColors.darkInk : KuboColors.ink,
      onPrimary: isDark ? KuboColors.darkPaper : KuboColors.paper,
      primaryContainer: isDark
          ? KuboColors.darkAccentSoft
          : KuboColors.accentSoft,
      onPrimaryContainer: isDark ? KuboColors.darkInk : KuboColors.ink,
      // Secondary marks what is chosen — a selected payment method, the
      // active tab. A weight, not a hue.
      secondary: isDark ? KuboColors.darkAccent : KuboColors.accent,
      onSecondary: isDark ? KuboColors.darkInk : KuboColors.paper,
      secondaryContainer: isDark
          ? KuboColors.darkAccentSoft
          : KuboColors.accentSoft,
      onSecondaryContainer: isDark ? KuboColors.darkInk : KuboColors.ink,
      tertiary: isDark ? KuboColors.darkAccentDeep : KuboColors.accentDeep,
      onTertiary: isDark ? KuboColors.darkInk : KuboColors.paper,
      tertiaryContainer: isDark
          ? KuboColors.darkAccentSoft
          : KuboColors.accentSoft,
      onTertiaryContainer: isDark ? KuboColors.darkInk : KuboColors.ink,
      // The one hue in the palette. Confirm this, or undo this — nothing else.
      error: isDark ? KuboColors.darkAlert : KuboColors.alert,
      onError: isDark ? KuboColors.darkPaper : Colors.white,
      errorContainer: isDark ? KuboColors.darkAlertSoft : KuboColors.alertSoft,
      onErrorContainer: isDark ? KuboColors.darkAlert : KuboColors.alert,
      surface: isDark ? KuboColors.darkPaper : KuboColors.paper,
      onSurface: isDark ? KuboColors.darkInk : KuboColors.ink,
      surfaceContainerLowest: isDark
          ? KuboColors.darkPaperSunk
          : KuboColors.paperRaised,
      surfaceContainerLow: isDark
          ? KuboColors.darkPaperRaised
          : KuboColors.paperRaised,
      surfaceContainer: isDark
          ? KuboColors.darkPaperMuted
          : KuboColors.paperMuted,
      surfaceContainerHigh: isDark
          ? KuboColors.darkAccentSoft
          : KuboColors.paperSunk,
      surfaceContainerHighest: isDark
          ? KuboColors.darkAccentDeep
          : KuboColors.accentSoft,
      onSurfaceVariant: isDark ? KuboColors.darkInkMuted : KuboColors.inkMuted,
      outline: isDark ? KuboColors.darkHairline : KuboColors.hairline,
      outlineVariant: isDark
          ? KuboColors.darkHairlineSoft
          : KuboColors.hairlineSoft,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: isDark ? KuboColors.darkInk : KuboColors.ink,
      onInverseSurface: isDark ? KuboColors.darkPaper : KuboColors.paper,
      inversePrimary: isDark ? KuboColors.ink : KuboColors.accentSoft,
    );

    final TextTheme text = _textTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: text,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outline,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KuboRadius.lg),
          side: BorderSide(color: scheme.outline),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(KuboTouch.payButton),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KuboRadius.md),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(KuboTouch.payButton),
          side: BorderSide(color: scheme.outline, width: 1.5),
          foregroundColor: scheme.onSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KuboRadius.md),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(KuboTouch.minTarget, KuboTouch.minTarget),
          foregroundColor: scheme.primary,
          textStyle: text.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(KuboTouch.minTarget, KuboTouch.minTarget),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: text.bodyLarge,
        subtitleTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        minVerticalPadding: KuboSpacing.md,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: KuboSpacing.lg,
          vertical: KuboSpacing.lg,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KuboRadius.md),
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KuboRadius.md),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(KuboRadius.md),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.secondaryContainer,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.secondaryContainer,
        selectedLabelTextStyle: text.labelMedium?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: text.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KuboRadius.md),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(KuboRadius.xl),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainer,
        selectedColor: scheme.secondaryContainer,
        side: BorderSide(color: scheme.outline),
        labelStyle: text.labelLarge,
        padding: const EdgeInsets.symmetric(
          horizontal: KuboSpacing.md,
          vertical: KuboSpacing.sm,
        ),
      ),
    );
  }

  /// Slightly larger than Material's defaults across the board: this is read
  /// at arm's length, in a hurry, sometimes with wet hands.
  static TextTheme _textTheme(ColorScheme scheme) {
    final Color ink = scheme.onSurface;
    final Color muted = scheme.onSurfaceVariant;
    return TextTheme(
      displaySmall: TextStyle(
        fontSize: 34,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: ink,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: ink,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        height: 1.25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: ink,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        height: 1.3,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        height: 1.35,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      titleSmall: TextStyle(
        fontSize: 15,
        height: 1.35,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      bodyLarge: TextStyle(fontSize: 17, height: 1.4, color: ink),
      bodyMedium: TextStyle(fontSize: 15, height: 1.4, color: ink),
      bodySmall: TextStyle(fontSize: 13, height: 1.4, color: muted),
      labelLarge: TextStyle(
        fontSize: 17,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: ink,
      ),
      labelMedium: TextStyle(
        fontSize: 13,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: muted,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: muted,
      ),
    );
  }
}
