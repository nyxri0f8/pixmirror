import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'motion.dart';

/// Liquid Glass variants, per Apple HIG:
///  * [regular] — blurs and adjusts luminosity; use for anything with text.
///  * [clear]   — highly translucent; only over rich media (the mirrored
///                screen), with a dimming layer when the content is bright.
enum GlassVariant { regular, clear }

/// Provides the "Reduce Transparency" preference to every glass surface.
class GlassScope extends InheritedWidget {
  const GlassScope({super.key, required this.reduceTransparency, required super.child});

  final bool reduceTransparency;

  static bool reduced(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassScope>()?.reduceTransparency ?? false;

  @override
  bool updateShouldNotify(GlassScope old) => old.reduceTransparency != reduceTransparency;
}

/// A frosted, light-bending glass surface for the controls layer.
///
/// Layers, bottom to top:
///  1. soft drop shadow (depth)
///  2. backdrop blur + saturation boost (frost + vibrancy)
///  3. tint: neutral by default, colored only for primary actions
///  4. luminous top-to-bottom sheen
///  5. specular rim: a gradient hairline brighter where "light" hits
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 28,
    this.variant = GlassVariant.regular,
    this.tint,
    this.padding = EdgeInsets.zero,
    this.shadow = true,
    this.dim = false,
  });

  final Widget child;
  final double radius;
  final GlassVariant variant;
  final Color? tint;
  final EdgeInsetsGeometry padding;
  final bool shadow;

  /// Adds the 35% dimming layer Apple recommends for clear glass over
  /// bright content.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);
    final reduced = GlassScope.reduced(context);

    if (reduced) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: tint ?? scheme.surfaceContainerHigh,
          borderRadius: shape,
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(padding: padding, child: child),
      );
    }

    final clear = variant == GlassVariant.clear;
    final baseTint = tint ??
        (dark
            ? scheme.surfaceContainerHighest.withValues(alpha: clear ? 0.10 : 0.42)
            : Colors.white.withValues(alpha: clear ? 0.10 : 0.48));
    final sigma = clear ? 10.0 : 26.0;

    Widget glass = ClipRRect(
      borderRadius: shape,
      child: BackdropFilter(
        filter: ui.ImageFilter.compose(
          outer: _saturate(clear ? 1.2 : 1.7),
          inner: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.mirror),
        ),
        child: CustomPaint(
          foregroundPainter: _RimPainter(radius: radius, dark: dark),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: shape,
              color: dim ? Colors.black.withValues(alpha: 0.35) : null,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: shape,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: dark ? 0.10 : 0.30),
                    Colors.white.withValues(alpha: dark ? 0.02 : 0.06),
                  ],
                ),
              ),
              position: DecorationPosition.foreground,
              child: ColoredBox(
                color: baseTint,
                child: Padding(padding: padding, child: child),
              ),
            ),
          ),
        ),
      ),
    );

    if (shadow) {
      glass = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: shape,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.35 : 0.10),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: glass,
      );
    }
    return glass;
  }

  static ColorFilter _saturate(double s) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final i = 1 - s;
    return ColorFilter.matrix([
      r * i + s, g * i, b * i, 0, 0,
      r * i, g * i + s, b * i, 0, 0,
      r * i, g * i, b * i + s, 0, 0,
      0, 0, 0, 1, 0,
    ]);
  }
}

class _RimPainter extends CustomPainter {
  _RimPainter({required this.radius, required this.dark});

  final double radius;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: dark ? 0.45 : 0.85),
          Colors.white.withValues(alpha: dark ? 0.06 : 0.20),
          Colors.white.withValues(alpha: dark ? 0.02 : 0.10),
          Colors.white.withValues(alpha: dark ? 0.22 : 0.55),
        ],
        stops: const [0, 0.35, 0.65, 1],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_RimPainter old) => old.radius != radius || old.dark != dark;
}

/// Circular glass icon button for toolbars.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 48,
    this.selected = false,
    this.variant = GlassVariant.regular,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final bool selected;
  final GlassVariant variant;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget button = PressScale(
      onTap: onPressed,
      child: SizedBox.square(
        dimension: size,
        child: Glass(
          radius: size / 2,
          variant: variant,
          shadow: false,
          tint: selected ? scheme.primary.withValues(alpha: 0.85) : null,
          child: Center(
            child: Icon(
              icon,
              size: size * 0.46,
              color: selected ? scheme.onPrimary : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) button = Tooltip(message: tooltip!, child: button);
    return Semantics(button: true, label: tooltip, child: button);
  }
}

/// Bare icon button meant to sit inside a [GlassBar] (avoids glass-on-glass).
class BarButton extends StatelessWidget {
  const BarButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.selected = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: PressScale(
          onTap: onPressed,
          scale: 0.86,
          child: SpringBuilder(
            value: selected ? 1 : 0,
            spring: Springs.defaultEffects,
            builder: (context, t, _) => Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.lerp(Colors.transparent, scheme.primary, t.clamp(0, 1)),
              ),
              child: Icon(
                icon,
                size: 22,
                color: Color.lerp(scheme.onSurface, scheme.onPrimary, t.clamp(0, 1)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Capsule toolbar made of a single glass surface.
class GlassBar extends StatelessWidget {
  const GlassBar({super.key, required this.children, this.variant = GlassVariant.regular});

  final List<Widget> children;
  final GlassVariant variant;

  @override
  Widget build(BuildContext context) => Glass(
        radius: 32,
        variant: variant,
        padding: const EdgeInsets.all(6),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      );
}
