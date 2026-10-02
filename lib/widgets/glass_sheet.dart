import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../ui/glass.dart';
import '../ui/motion.dart';

/// Presents [builder] on a glass panel: a bottom sheet on phones, a centered
/// card on wide windows. Entry uses an M3 spatial spring.
Future<T?> showGlassPanel<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
  double maxWidth = 520,
}) {
  return Navigator.of(context).push<T>(PageRouteBuilder<T>(
    opaque: false,
    barrierDismissible: dismissible,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 520),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) {
      final wide = MediaQuery.sizeOf(context).width > 640;
      final panel = ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        child: Glass(
          radius: 32,
          child: Material(type: MaterialType.transparency, child: builder(context)),
        ),
      );
      return SafeArea(
        child: Align(
          alignment: wide ? Alignment.center : Alignment.bottomCenter,
          child: Padding(padding: const EdgeInsets.all(12), child: panel),
        ),
      );
    },
    transitionsBuilder: (context, animation, _, child) {
      final wide = MediaQuery.sizeOf(context).width > 640;
      return AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          final forward = animation.status != AnimationStatus.reverse;
          final t = forward
              ? _springCurve.transform(animation.value)
              : Curves.easeInCubic.transform(animation.value);
          final blur = 6 * animation.value;
          return BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: Opacity(
              opacity: animation.value.clamp(0, 1),
              child: wide
                  ? Transform.scale(scale: 0.9 + 0.1 * t, child: child)
                  : FractionalTranslation(translation: Offset(0, (1 - t) * 0.5), child: child),
            ),
          );
        },
      );
    },
  ));
}

/// Default spatial spring sampled into a curve so route transitions share
/// the same feel as interactive springs (the route lasts ~0.52 s).
final _springCurve = _SpringCurve();

class _SpringCurve extends Curve {
  final _sim = SpringSimulation(Springs.defaultSpatial, 0, 1, 0);

  @override
  double transformInternal(double t) => _sim.x(t * 0.52);
}
