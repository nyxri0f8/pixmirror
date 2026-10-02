import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import '../core/discovery.dart';
import '../core/host_server.dart';
import '../core/remote_session.dart';
import '../ui/glass.dart';
import '../ui/motion.dart';
import 'glass_sheet.dart';

IconData deviceIcon(String platform) =>
    platform == 'android' ? Icons.smartphone_rounded : Icons.laptop_windows_rounded;

/// Dynamic-Island style capsule that drops in when a paired device that is
/// sharing comes into range: "Pixel 8 is nearby · Mirror".
class NearbyBanner extends StatefulWidget {
  const NearbyBanner({super.key, required this.peer, required this.onOpen, required this.onDismiss});

  final Peer peer;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  State<NearbyBanner> createState() => _NearbyBannerState();
}

class _NearbyBannerState extends State<NearbyBanner> {
  bool _shown = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _shown = true));
    _timer = Timer(const Duration(seconds: 9), _hide);
    HapticFeedback.lightImpact();
  }

  void _hide() {
    if (!mounted) return;
    setState(() => _shown = false);
    Future.delayed(const Duration(milliseconds: 400), widget.onDismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SpringBuilder(
      value: _shown ? 1 : 0,
      spring: Springs.defaultSpatial,
      builder: (context, t, child) => Transform.translate(
        offset: Offset(0, -120 * (1 - t)),
        child: Transform.scale(scale: 0.8 + 0.2 * t, child: Opacity(opacity: t.clamp(0, 1), child: child)),
      ),
      child: GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < 0) _hide();
        },
        child: Glass(
          radius: 34,
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: scheme.primaryContainer,
                child: Icon(deviceIcon(widget.peer.platform), color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.peer.name, style: text.titleSmall, overflow: TextOverflow.ellipsis),
                    Text('Nearby and ready', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              FilledButton(
                onPressed: () {
                  _timer?.cancel();
                  widget.onOpen();
                },
                child: Text(widget.peer.isPhone ? 'Mirror' : 'Control'),
              ),
              IconButton(
                tooltip: 'Dismiss',
                onPressed: _hide,
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Host side: "Pixel 8 wants to connect. Code 123 456. Allow / Don't allow".
Future<void> showPairPrompt(BuildContext context, HostServer server, PairRequest req) {
  return showGlassPanel(
    context,
    dismissible: false,
    maxWidth: 420,
    builder: (context) => _PairPanel(server: server, req: req),
  );
}

class _PairPanel extends StatefulWidget {
  const _PairPanel({required this.server, required this.req});
  final HostServer server;
  final PairRequest req;

  @override
  State<_PairPanel> createState() => _PairPanelState();
}

class _PairPanelState extends State<_PairPanel> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.server.addListener(_check);
  }

  @override
  void dispose() {
    widget.server.removeListener(_check);
    super.dispose();
  }

  /// Closes the prompt if the other device gave up or timed out.
  void _check() {
    if (!identical(widget.server.pendingPair, widget.req)) _answer(null);
  }

  void _answer(bool? allow) {
    if (_closed) return;
    _closed = true;
    if (allow != null) widget.server.answerPair(allow);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final req = widget.req;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulseIcon(icon: deviceIcon(req.platform)),
          const SizedBox(height: 18),
          Text('${req.name} wants to connect', style: text.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'Check that this code matches the one on ${req.name}. Once paired, '
            'it can see and control this device whenever you connect.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          _Code(code: req.code),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _answer(false),
                  child: const Text("Don't allow"),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => _answer(true),
                  child: const Text('Allow'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Code extends StatelessWidget {
  const _Code({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        '${code.substring(0, 3)} ${code.substring(3)}',
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: scheme.onPrimaryContainer,
              letterSpacing: 4,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
      ),
    );
  }
}

/// Phone side: a paired PC wants to mirror this phone while sharing is off.
Future<void> showShareRequest(BuildContext context, AppController app, ShareRequest req) {
  return showGlassPanel(
    context,
    dismissible: false,
    maxWidth: 420,
    builder: (context) => _ShareRequestPanel(app: app, req: req),
  );
}

class _ShareRequestPanel extends StatefulWidget {
  const _ShareRequestPanel({required this.app, required this.req});
  final AppController app;
  final ShareRequest req;

  @override
  State<_ShareRequestPanel> createState() => _ShareRequestPanelState();
}

class _ShareRequestPanelState extends State<_ShareRequestPanel> {
  bool _closed = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    widget.app.server.addListener(_check);
  }

  @override
  void dispose() {
    widget.app.server.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!identical(widget.app.server.shareRequest, widget.req)) _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PulseIcon(icon: Icons.laptop_windows_rounded),
          const SizedBox(height: 18),
          Text('${widget.req.name} wants to mirror this phone',
              style: text.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'Your screen will appear on ${widget.req.name}. Next, Android asks what to share: '
            'choose “Entire screen”.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _starting
                      ? null
                      : () {
                          widget.app.declineShareRequest();
                          _close();
                        },
                  child: const Text('Not now'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _starting
                      ? null
                      : () async {
                          setState(() => _starting = true);
                          await widget.app.acceptShareRequest();
                          _close();
                        },
                  child: const Text('Start sharing'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Viewer side: shown while connecting / waiting for approval / on error.
/// Resolves to true once the session is live.
Future<bool?> showConnectPanel(BuildContext context, RemoteSession session) {
  return showGlassPanel<bool>(
    context,
    dismissible: false,
    maxWidth: 400,
    builder: (context) => _ConnectPanel(session: session),
  );
}

class _ConnectPanel extends StatefulWidget {
  const _ConnectPanel({required this.session});
  final RemoteSession session;

  @override
  State<_ConnectPanel> createState() => _ConnectPanelState();
}

class _ConnectPanelState extends State<_ConnectPanel> {
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (widget.session.phase == SessionPhase.live && !_popped) {
      _popped = true;
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final (title, body) = switch (s.phase) {
      SessionPhase.connecting => ('Connecting to ${s.peer.name}…', 'Hold tight, this takes a second.'),
      SessionPhase.awaitingApproval => (
          'Confirm on ${s.peer.name}',
          'Make sure this code is shown there, then choose Allow.'
        ),
      SessionPhase.awaitingShare => (
          'Tap “Start sharing” on ${s.peer.name}',
          'Your phone is asking now. When Android asks what to share, choose “Entire screen”.'
        ),
      SessionPhase.closed => ("Couldn't connect", s.error ?? 'Something went wrong.'),
      SessionPhase.live => ('Connected', ''),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulseIcon(
            icon: s.phase == SessionPhase.closed
                ? Icons.link_off_rounded
                : deviceIcon(s.peer.platform),
            animate: s.phase != SessionPhase.closed,
            color: s.phase == SessionPhase.closed ? scheme.error : null,
          ),
          const SizedBox(height: 18),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(title, key: ValueKey(title), style: text.titleLarge, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 8),
          Text(body,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center),
          if (s.pairCode != null && s.phase == SessionPhase.awaitingApproval) ...[
            const SizedBox(height: 18),
            _Code(code: s.pairCode!),
          ],
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: s.phase == SessionPhase.closed
                ? FilledButton.tonal(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('OK'),
                  )
                : OutlinedButton(
                    onPressed: () {
                      _popped = true;
                      s.close();
                      Navigator.of(context).pop(false);
                    },
                    child: const Text('Cancel'),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Device glyph with expanding radar rings.
class _PulseIcon extends StatefulWidget {
  const _PulseIcon({required this.icon, this.animate = true, this.color});
  final IconData icon;
  final bool animate;
  final Color? color;

  @override
  State<_PulseIcon> createState() => _PulseIconState();
}

class _PulseIconState extends State<_PulseIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void didUpdateWidget(_PulseIcon old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_c.isAnimating) _c.repeat();
    if (!widget.animate) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.color ?? scheme.primary;
    return SizedBox.square(
      dimension: 96,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => CustomPaint(
          painter: _RingsPainter(widget.animate ? _c.value : -1, color),
          child: child,
        ),
        child: Center(
          child: CircleAvatar(
            radius: 30,
            backgroundColor: color.withValues(alpha: 0.16),
            child: Icon(widget.icon, size: 30, color: color),
          ),
        ),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (t < 0) return;
    final c = size.center(Offset.zero);
    for (var i = 0; i < 2; i++) {
      final p = (t + i * 0.5) % 1;
      canvas.drawCircle(
        c,
        30 + p * (size.width / 2 - 30),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: (1 - p) * 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.t != t || old.color != color;
}

/// Radar shown while searching for devices.
class SearchingRadar extends StatefulWidget {
  const SearchingRadar({super.key});

  @override
  State<SearchingRadar> createState() => _SearchingRadarState();
}

class _SearchingRadarState extends State<SearchingRadar> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox.square(
      dimension: 140,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(painter: _RadarPainter(_c.value, color)),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(
        c,
        r * i / 3,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = color.withValues(alpha: 0.18),
      );
    }
    final sweep = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi / 2,
        colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.45)],
        transform: GradientRotation(t * 2 * math.pi),
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r, sweep);
    canvas.drawCircle(c, 5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.t != t;
}
