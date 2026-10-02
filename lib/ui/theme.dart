import 'package:flutter/material.dart';

/// Brand seed used when the OS offers no dynamic color.
const kSeed = Color(0xFF5B5BF7);

/// Material 3 theme. Colors come from the wallpaper (Android 12+) or the
/// Windows accent color via dynamic_color, falling back to [kSeed].
ThemeData buildTheme(ColorScheme? dynamicScheme, Brightness brightness) {
  final scheme = (dynamicScheme?._fromAccent() ??
          ColorScheme.fromSeed(
            seedColor: kSeed,
            brightness: brightness,
            dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
          ))
      .copyWith(brightness: brightness);

  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final text = base.textTheme.apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text.copyWith(
      displaySmall: text.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1),
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: const StadiumBorder(),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48), shape: const StadiumBorder()),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48), shape: const StadiumBorder()),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(minimumSize: const Size(0, 44)),
    ),
    switchTheme: const SwitchThemeData(),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(10),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}

extension on ColorScheme {
  // Rebuild from the OS accent so every M3 surface-container role exists
  // (older dynamic schemes omit them).
  ColorScheme _fromAccent() => ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
      );
}
