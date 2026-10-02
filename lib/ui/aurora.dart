import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Soft color fields behind the UI. Glass needs something rich underneath
/// to refract; this gives every screen that depth.
///
/// Deliberately static: an animated backdrop forces every glass blur to be
/// recomputed each frame, and on the PC it would also make the mirrored
/// screen "change" constantly and stream non-stop.
class Aurora extends StatelessWidget {
  const Aurora({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: _AuroraPainter(
              base: scheme.surface,
              colors: [
                scheme.primary.withValues(alpha: dark ? 0.55 : 0.45),
                scheme.tertiary.withValues(alpha: dark ? 0.45 : 0.38),
                scheme.secondary.withValues(alpha: dark ? 0.40 : 0.30),
                scheme.primaryContainer.withValues(alpha: dark ? 0.50 : 0.70),
              ],
            ),
          ),
        ),
        ?child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({required this.base, required this.colors});

  final Color base;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final longest = size.longestSide;
    const blobs = [(0.12, 0.10), (0.92, 0.28), (0.25, 0.85), (0.80, 0.95)];
    for (var i = 0; i < colors.length; i++) {
      final (cx, cy) = blobs[i];
      final center = Offset(size.width * cx, size.height * cy);
      final radius = longest * (0.42 + 0.06 * math.sin(i * 1.7));
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [colors[i], colors[i].withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.base != base || old.colors != colors;
}
