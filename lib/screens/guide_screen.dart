import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../platform/android_host.dart';
import '../ui/aurora.dart';
import '../ui/glass.dart';
import '../ui/motion.dart';
import '../widgets/glass_sheet.dart';

/// "How it works" — three steps, shown from the header on both apps.
Future<void> showHowItWorks(BuildContext context, AppController app) => showGlassPanel(
      context,
      maxWidth: 560,
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('How it works', style: Theme.of(context).textTheme.headlineMedium)),
                IconButton.filledTonal(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const _HowSteps(),
          ],
        ),
      ),
    );

class _HowSteps extends StatelessWidget {
  const _HowSteps();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        _Step(
          n: 1,
          icon: Icons.wifi_rounded,
          title: 'Same Wi-Fi',
          body: 'Open PixMirror on your phone and your PC. They find each other automatically '
              'on your network — no cables, no accounts.',
        ),
        _Step(
          n: 2,
          icon: Icons.pin_rounded,
          title: 'Pair once',
          body: 'Tap Pair. A 6-digit code appears on both screens; if they match, choose Allow. '
              'From then on the two devices trust each other in both directions.',
        ),
        _Step(
          n: 3,
          icon: Icons.phone_iphone_rounded,
          title: 'Mirror your phone on the PC',
          body: 'Click Mirror on the PC. Your phone asks to start sharing — tap Start sharing and '
              'pick “Entire screen”. Click to tap, drag to swipe, scroll to scroll, type to type.',
        ),
        _Step(
          n: 4,
          icon: Icons.touch_app_rounded,
          title: 'Control your PC from the phone',
          body: 'Tap Control on the phone. Use it like a laptop trackpad: drag to move, tap to click, '
              'two fingers to scroll or right-click, pinch to zoom, and the keyboard button to type.',
          last: true,
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.icon, required this.title, required this.body, this.last = false});

  final int n;
  final IconData icon;
  final String title;
  final String body;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: scheme.primary,
                child: Icon(icon, size: 20, color: scheme.onPrimary),
              ),
              if (!last)
                Expanded(
                  child: Container(width: 2, margin: const EdgeInsets.symmetric(vertical: 4), color: scheme.primary.withValues(alpha: 0.3)),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 20, top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$n. $title', style: text.titleMedium),
                  const SizedBox(height: 4),
                  Text(body, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// First-run setup on the phone: what PixMirror does, then the Android
/// permissions remote control needs (restricted settings → accessibility →
/// notifications → battery).
class SetupGuideScreen extends StatefulWidget {
  const SetupGuideScreen({super.key, required this.app, required this.onDone});

  final AppController app;
  final VoidCallback onDone;

  @override
  State<SetupGuideScreen> createState() => _SetupGuideScreenState();
}

class _SetupGuideScreenState extends State<SetupGuideScreen> with WidgetsBindingObserver {
  final _pages = PageController();
  int _page = 0;
  static const _count = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.app.addListener(_changed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.app.removeListener(_changed);
    _pages.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from system settings: re-check whether remote control is on.
    if (state == AppLifecycleState.resumed) widget.app.refreshPhoneInput();
  }

  void _next() {
    if (_page == _count - 1) {
      widget.onDone();
    } else {
      _pages.nextPage(duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready = widget.app.phoneInputReady;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Aurora(
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: TextButton(onPressed: widget.onDone, child: const Text('Skip')),
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [
                    const _Page(
                      icon: Icons.devices_rounded,
                      title: 'Welcome to PixMirror',
                      body: 'Mirror this phone on your PC, or use it to control your PC — like '
                          'iPhone Mirroring, for Android and Windows.\n\nThe next steps take about a minute.',
                    ),
                    const _Page(
                      icon: Icons.route_rounded,
                      title: 'How it works',
                      child: _HowSteps(),
                    ),
                    _Page(
                      icon: Icons.admin_panel_settings_rounded,
                      title: 'Allow restricted settings',
                      body: 'Android blocks accessibility for apps installed from a file until you '
                          'allow it once. Skip this if you installed from a store.',
                      steps: const [
                        'Tap “Open Accessibility” on the next page and try turning on PixMirror once — Android will say it is restricted. Come back here.',
                        'Tap “Open App info” below.',
                        'Tap ⋮ (top-right) → “Allow restricted settings”, then confirm with your PIN.',
                      ],
                      action: 'Open App info',
                      onAction: () => native.invokeMethod('openAppInfo'),
                    ),
                    _Page(
                      icon: ready ? Icons.check_circle_rounded : Icons.touch_app_rounded,
                      iconColor: ready ? const Color(0xFF34C759) : null,
                      title: ready ? 'Remote control is on' : 'Turn on remote control',
                      body: ready
                          ? 'Your PC can now tap, swipe and type on this phone while mirroring.'
                          : 'This lets your PC tap, swipe and type on this phone. PixMirror only acts '
                              'on input from devices you paired.',
                      steps: ready
                          ? const []
                          : const [
                              'Tap “Open Accessibility”.',
                              'Find “Downloaded apps” (or “Installed apps”) → “PixMirror remote control”.',
                              'Turn it on and confirm. Then come back — this page turns green.',
                            ],
                      action: ready ? null : 'Open Accessibility',
                      onAction: widget.app.openPhoneInputSettings,
                    ),
                    _Page(
                      icon: Icons.notifications_active_rounded,
                      title: 'Stay reachable',
                      body: 'Notifications let your PC ask to mirror even when PixMirror is in the '
                          'background. For the most reliable connection, set battery to “Unrestricted”.',
                      action: 'Allow notifications',
                      onAction: () => native.invokeMethod('requestNotifications'),
                      secondary: 'Battery settings',
                      onSecondary: () => native.invokeMethod('openBatterySettings'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: Row(
                  children: [
                    for (var i = 0; i < _count; i++)
                      SpringBuilder(
                        value: i == _page ? 1 : 0,
                        spring: Springs.fastSpatial,
                        builder: (context, t, _) => Container(
                          width: 8 + 16 * t.clamp(0, 1.2),
                          height: 8,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: Color.lerp(scheme.outlineVariant, scheme.primary, t.clamp(0, 1)),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _next,
                      child: Text(_page == _count - 1 ? 'Get started' : 'Next'),
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

class _Page extends StatelessWidget {
  const _Page({
    required this.icon,
    required this.title,
    this.body,
    this.child,
    this.steps = const [],
    this.action,
    this.onAction,
    this.secondary,
    this.onSecondary,
    this.iconColor,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? body;
  final Widget? child;
  final List<String> steps;
  final String? action;
  final VoidCallback? onAction;
  final String? secondary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Glass(
        radius: 32,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: (iconColor ?? scheme.primary).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(icon, size: 34, color: iconColor ?? scheme.primary),
            ),
            const SizedBox(height: 18),
            Text(title, style: text.headlineMedium),
            if (body != null) ...[
              const SizedBox(height: 10),
              Text(body!, style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            if (child != null) ...[const SizedBox(height: 16), child!],
            if (steps.isNotEmpty) ...[
              const SizedBox(height: 18),
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 13,
                        backgroundColor: scheme.primaryContainer,
                        child: Text('${i + 1}',
                            style: text.labelLarge?.copyWith(color: scheme.onPrimaryContainer)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(steps[i], style: text.bodyMedium)),
                    ],
                  ),
                ),
            ],
            if (action != null) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.tonal(onPressed: onAction, child: Text(action!)),
                  if (secondary != null) OutlinedButton(onPressed: onSecondary, child: Text(secondary!)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
