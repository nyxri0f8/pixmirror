import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Material 3 Expressive motion tokens (androidx ExpressiveMotionTokens).
/// Spatial springs move things and may overshoot; effects springs change
/// color/opacity and never bounce.
abstract final class Springs {
  static SpringDescription _s(double stiffness, double damping) =>
      SpringDescription.withDampingRatio(mass: 1, stiffness: stiffness, ratio: damping);

  static final fastSpatial = _s(800, 0.6);
  static final defaultSpatial = _s(380, 0.8);
  static final slowSpatial = _s(200, 0.8);
  static final fastEffects = _s(3800, 1.0);
  static final defaultEffects = _s(1600, 1.0);
  static final slowEffects = _s(800, 1.0);
}

/// Implicitly animates [value] with a spring, preserving velocity when the
/// target changes mid-flight — the thing that makes motion feel "liquid".
class SpringBuilder extends StatefulWidget {
  const SpringBuilder({
    super.key,
    required this.value,
    required this.builder,
    this.spring,
    this.child,
  });

  final double value;
  final SpringDescription? spring;
  final Widget? child;
  final Widget Function(BuildContext context, double value, Widget? child) builder;

  @override
  State<SpringBuilder> createState() => _SpringBuilderState();
}

class _SpringBuilderState extends State<SpringBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: widget.value);

  @override
  void didUpdateWidget(SpringBuilder old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        _c.value = widget.value;
        return;
      }
      _c.animateWith(SpringSimulation(
        widget.spring ?? Springs.defaultSpatial,
        _c.value,
        widget.value,
        _c.velocity,
      ));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, child) => widget.builder(context, _c.value, child),
        child: widget.child,
      );
}

/// Squishes on press with a fast spatial spring (M3 Expressive "press morph").
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.onTap, this.scale = 0.94});

  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTap: widget.onTap,
      child: SpringBuilder(
        value: _down ? widget.scale : 1,
        spring: Springs.fastSpatial,
        child: widget.child,
        builder: (context, v, child) => Transform.scale(scale: v, child: child),
      ),
    );
  }
}
