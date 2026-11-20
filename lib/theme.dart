import 'package:flutter/material.dart';

/// Builds the app's theme. Light and dark are both full designs, not a dark
/// filter on the light one: each has its own surfaces, text and accent tones.
ThemeData buildTheme({bool dark = false}) {
  final palette = dark ? _Palette.dark : _Palette.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0E7C66),
    brightness: dark ? Brightness.dark : Brightness.light,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  ).copyWith(
    primary: palette.primary,
    onPrimary: palette.onPrimary,
    primaryContainer: palette.primaryContainer,
    onPrimaryContainer: palette.onPrimaryContainer,
    surface: palette.surface,
    onSurface: palette.onSurface,
    onSurfaceVariant: palette.onSurfaceVariant,
    surfaceContainerLowest: palette.surfaceLowest,
    surfaceContainerLow: palette.surfaceLow,
    surfaceContainer: palette.surfaceMid,
    surfaceContainerHigh: palette.surfaceHigh,
    surfaceContainerHighest: palette.surfaceHighest,
    outline: palette.outline,
    outlineVariant: palette.outlineVariant,
  );

  final base = ThemeData(brightness: dark ? Brightness.dark : Brightness.light).textTheme;
  final text = base.copyWith(
    displaySmall: base.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
    headlineMedium: base.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4),
    headlineSmall: base.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3),
    titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.1),
    titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.1),
  );
  // Button and chip styles must name the font too. A style without a family
  // replaces the inherited one and renders in the engine's fallback font.
  final family = base.bodyMedium?.fontFamily;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor: palette.scaffold,
    visualDensity: VisualDensity.standard,
    dividerColor: palette.outlineVariant,
    dividerTheme: DividerThemeData(color: palette.outlineVariant, thickness: 1, space: 1),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: palette.outlineVariant),
      backgroundColor: palette.surfaceMid,
      labelStyle: TextStyle(fontWeight: FontWeight.w600, fontFamily: family, color: palette.onSurface),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xxs),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surfaceHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.primary, width: 1.6),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      labelStyle: TextStyle(color: palette.onSurfaceVariant),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: palette.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.outlineVariant.withValues(alpha: dark ? 0.7 : 0.6)),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md + 2),
        textStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, fontFamily: family),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        side: BorderSide(color: palette.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    // Every icon button is at least a 44px touch target (the tills may be touch screens).
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
    ),
    dataTableTheme: DataTableThemeData(
      headingRowColor: WidgetStatePropertyAll(palette.surfaceMid),
      headingTextStyle: TextStyle(fontWeight: FontWeight.w700, color: palette.onSurfaceVariant, fontSize: 12.5),
      dataTextStyle: TextStyle(fontSize: 13.5, color: palette.onSurface),
      dividerThickness: 1,
      horizontalMargin: AppSpacing.lg,
      columnSpacing: AppSpacing.xl,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.dialog,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        color: palette.onSurface,
        fontFamily: family,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.dialog,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? palette.surfaceHighest : palette.onSurface,
      contentTextStyle: TextStyle(color: dark ? palette.onSurface : palette.surface, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: palette.onSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: palette.surface, fontSize: 12, fontWeight: FontWeight.w500),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.surface,
      foregroundColor: palette.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: palette.primary),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? palette.onPrimary : palette.onSurfaceVariant,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? palette.primary : palette.surfaceHighest,
      ),
    ),
  );
}

/// Every colour the light and dark designs use. Nothing outside this file
/// picks a surface colour, so one change here restyles the whole app.
class _Palette {
  const _Palette({
    required this.scaffold,
    required this.surfaceLowest,
    required this.surfaceLow,
    required this.surfaceMid,
    required this.surfaceHigh,
    required this.surfaceHighest,
    required this.surface,
    required this.card,
    required this.dialog,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
  });

  final Color scaffold, surfaceLowest, surfaceLow, surfaceMid, surfaceHigh, surfaceHighest, surface, card, dialog;
  final Color primary, onPrimary, primaryContainer, onPrimaryContainer;
  final Color onSurface, onSurfaceVariant, outline, outlineVariant;

  static const light = _Palette(
    scaffold: Color(0xFFF2F6F5),
    surfaceLowest: Color(0xFFFFFFFF),
    surfaceLow: Color(0xFFF5F8F7),
    surfaceMid: Color(0xFFEDF2F0),
    surfaceHigh: Color(0xFFE6EDEA),
    surfaceHighest: Color(0xFFDDE6E2),
    surface: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    dialog: Color(0xFFFFFFFF),
    primary: Color(0xFF0B6B58),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFCDEEE3),
    onPrimaryContainer: Color(0xFF062E25),
    onSurface: Color(0xFF13201D),
    onSurfaceVariant: Color(0xFF45554F),
    outline: Color(0xFF75857F),
    outlineVariant: Color(0xFFD0DCD7),
  );

  /// Deep ink-green, matching the sidebar gradient, so the two read as one design.
  static const dark = _Palette(
    scaffold: Color(0xFF09161A),
    surfaceLowest: Color(0xFF071226),
    surfaceLow: Color(0xFF0D1E23),
    surfaceMid: Color(0xFF122A30),
    surfaceHigh: Color(0xFF18343B),
    surfaceHighest: Color(0xFF203F47),
    surface: Color(0xFF0F2026),
    card: Color(0xFF122A30),
    dialog: Color(0xFF17303A),
    primary: Color(0xFF2ED3A4),
    onPrimary: Color(0xFF04211A),
    primaryContainer: Color(0xFF0E4A3D),
    onPrimaryContainer: Color(0xFFBFF5E2),
    onSurface: Color(0xFFE4F1EE),
    onSurfaceVariant: Color(0xFFADC3BE),
    outline: Color(0xFF7D9893),
    outlineVariant: Color(0xFF2B4A51),
  );
}

/// Semantic colours (good, warn, danger...). They switch with the theme.
///
/// Set [dark] before the screens build; the app does this from the chosen
/// theme mode. Read these getters anywhere, with or without a BuildContext.
class AppColors {
  AppColors._();

  static bool dark = false;

  static Color get good => dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);
  static Color get warn => dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
  static Color get danger => dark ? const Color(0xFFF87171) : const Color(0xFFB91C1C);
  static Color get info => dark ? const Color(0xFF7DB8FF) : const Color(0xFF1D4ED8);
  static Color get cash => dark ? const Color(0xFF34D3A4) : const Color(0xFF0B6B58);
  static Color get credit => warn;
}

/// The look of the sidebar and the hero panels: a deep ink gradient with an
/// emerald glow for the active item. The same in both modes, so the brand stays.
class ShellStyle {
  static const inkTop = Color(0xFF0B1A1E);
  static const inkBottom = Color(0xFF10292E);
  static const emerald = Color(0xFF12B58A);
  static const emeraldDeep = Color(0xFF0B8C6A);
  static const mist = Color(0xFFB9CCC8);
  static const railExpanded = 236.0;
  static const railCollapsed = 80.0;
}

/// One spacing scale for the whole app. Screens use these names, not literals,
/// so padding stays consistent from the till to the reports.
class AppSpacing {
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;

  /// Padding around a whole screen.
  static const page = xl;
  /// Gap between the cards on a screen.
  static const section = lg;
  /// Padding inside a card.
  static const card = lg;
  static const dialogContent = lg;
  static const dialogInner = md;
  static const controlGap = sm;
}
