import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/aurora.dart';
import '../ui/motion.dart';

/// Launch screen: the logo springs in on a glass halo while the app starts
/// discovery and its host server behind it. Finishes when [ready] completes
/// and at least [minDuration] has passed, then calls [onDone].
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.ready,
    required this.onDone,
    this.minDuration = const Duration(milliseconds: 1500),
  });

  final Future<void> ready;
  final VoidCallback onDone;
  final Duration minDuration;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  bool _in = false;
  late final AnimationController _halo =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..repeat();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _in = true);
    });
    Future.wait([widget.ready, Future.delayed(widget.minDuration)]).then((_) {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _halo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Aurora(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 220,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _halo,
                      builder: (context, _) => CustomPaint(
                        size: const Size.square(220),
                        painter: _HaloPainter(_halo.value, scheme.primary),
                      ),
                    ),
                    SpringBuilder(
                      value: _in ? 1 : 0,
                      spring: Springs.slowSpatial,
                      builder: (context, t, child) => Transform.scale(
                        scale: 0.55 + 0.45 * t,
                        child: Transform.rotate(angle: (1 - t) * -0.25, child: child),
                      ),
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(32),
                          boxShadow: [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.45),
                              blurRadius: 40,
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: Image.asset('assets/logo.png', filterQuality: FilterQuality.medium),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SpringBuilder(
                value: _in ? 1 : 0,
                spring: Springs.defaultSpatial,
                builder: (context, t, child) => Opacity(
                  opacity: t.clamp(0, 1),
                  child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
                ),
                child: Column(
                  children: [
                    Text('PixMirror', style: text.displaySmall),
                    const SizedBox(height: 6),
                    Text(
                      'Your phone and PC, one seamless screen',
                      style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HaloPainter extends CustomPainter {
  _HaloPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1;
      final r = 62 + p * (size.width / 2 - 62);
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 + 6 * (1 - p)
          ..color = color.withValues(alpha: 0.35 * math.pow(1 - p, 2).toDouble()),
      );
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) => old.t != t || old.color != color;
}
