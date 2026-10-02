import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/discovery.dart';
import '../core/host_server.dart';
import '../desktop/desktop_shell.dart';
import '../platform/android_host.dart';
import '../ui/aurora.dart';
import '../ui/glass.dart';
import '../ui/motion.dart';
import '../widgets/popups.dart';
import 'guide_screen.dart';
import 'settings_sheet.dart';
import 'viewer_screen.dart';

/// Two clear functions per device:
///  * PC:    "Mirror your phone"   +  "Control this PC from your phone"
///  * Phone: "Control your PC"     +  "Mirror this phone on your PC"
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.app});

  final AppController app;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  AppController get app => widget.app;
  StreamSubscription<Peer>? _nearbySub;
  final List<Peer> _banners = [];
  PairRequest? _shownPair;
  ShareRequest? _shownShare;
  bool _connecting = false;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.addListener(_onApp);
    _nearbySub = app.nearby.listen(_onNearby);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(_onApp);
    _nearbySub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    // Coming back from Accessibility settings.
    if (state == AppLifecycleState.resumed) app.refreshPhoneInput();
  }

  void _onApp() {
    final pair = app.server.pendingPair;
    if (pair != null && !identical(pair, _shownPair)) {
      _shownPair = pair;
      final shell = DesktopShell.instance;
      if (!shell.visible) {
        shell.toast('${pair.name} wants to connect', 'Click to review the pairing code.');
      }
      shell.show();
      showPairPrompt(context, app.server, pair);
    }
    final share = app.server.shareRequest;
    if (share != null && !identical(share, _shownShare)) {
      _shownShare = share;
      if (Platform.isAndroid && _lifecycle != AppLifecycleState.resumed) {
        native.invokeMethod('notifyRequest', {'name': share.name});
      }
      showShareRequest(context, app, share);
    }
    if (mounted) setState(() {});
  }

  void _onNearby(Peer peer) {
    if (!app.store.notifyNearby || app.session != null) return;
    final shell = DesktopShell.instance;
    if (!shell.visible) {
      shell.toast(
        '${peer.name} is nearby',
        peer.isPhone ? 'Click to mirror your phone.' : 'Click to control your PC.',
        onClick: () => _connect(peer),
      );
      return;
    }
    setState(() {
      _banners.removeWhere((p) => p.id == peer.id);
      _banners.add(peer);
    });
  }

  Future<void> _connect(Peer peer) async {
    if (_connecting) return;
    _connecting = true;
    setState(() => _banners.removeWhere((p) => p.id == peer.id));
    final session = app.connect(peer);
    final ok = await showConnectPanel(context, session);
    _connecting = false;
    if (!mounted) return;
    if (ok == true) {
      await Navigator.of(context).push(viewerRoute(app, session));
    }
    if (app.session == session) app.endSession();
  }

  Future<void> _toggleSharing(bool on) async {
    final ok = await app.setSharing(on);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Screen sharing needs your OK. Choose "Entire screen" when asked.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 860;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Aurora(
        child: Stack(
          children: [
            Column(
              children: [
                if (app.isDesktop) const TitleBar(),
                Expanded(
                  child: SafeArea(
                    top: !app.isDesktop,
                    child: wide ? _wideLayout() : _narrowLayout(),
                  ),
                ),
              ],
            ),
            // Nearby banners drop in from the top, like a Dynamic Island.
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.only(top: app.isDesktop ? 44 : 8, left: 12, right: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final p in _banners)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: NearbyBanner(
                            key: ValueKey(p.id),
                            peer: p,
                            onOpen: () => _connect(p),
                            onDismiss: () => setState(() => _banners.remove(p)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('PixMirror', style: text.displaySmall),
              const SizedBox(height: 2),
              Text(
                'Your phone and PC, one seamless screen.',
                style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        GlassIconButton(
          icon: Icons.help_outline_rounded,
          tooltip: 'How it works',
          onPressed: () => showHowItWorks(context, app),
        ),
        const SizedBox(width: 10),
        GlassIconButton(
          icon: Icons.settings_rounded,
          tooltip: 'Settings',
          onPressed: () => showSettings(context, app),
        ),
      ],
    );
  }

  Widget get _connectCard => _ConnectCard(app: app, onConnect: _connect);
  Widget get _shareCard => _ShareCard(app: app, onToggle: _toggleSharing);

  Widget _narrowLayout() => ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          _header(),
          const SizedBox(height: 24),
          _connectCard,
          const SizedBox(height: 16),
          _shareCard,
        ],
      );

  Widget _wideLayout() => Padding(
        padding: const EdgeInsets.fromLTRB(36, 20, 36, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const SizedBox(height: 28),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 6, child: SingleChildScrollView(child: _connectCard)),
                  const SizedBox(width: 24),
                  Expanded(flex: 5, child: SingleChildScrollView(child: _shareCard)),
                ],
              ),
            ),
          ],
        ),
      );
}

/// Card heading: big tonal icon, title and one-line explanation.
class _FunctionHeader extends StatelessWidget {
  const _FunctionHeader({required this.icon, required this.title, required this.subtitle, this.active = false});

  final IconData icon;
  final String title;
  final String subtitle;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        SpringBuilder(
          value: active ? 1 : 0,
          spring: Springs.defaultEffects,
          builder: (context, t, _) => Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Color.lerp(scheme.primaryContainer, scheme.primary, t.clamp(0, 1)),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: Color.lerp(scheme.onPrimaryContainer, scheme.onPrimary, t.clamp(0, 1))),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: text.titleLarge),
              const SizedBox(height: 2),
              Text(subtitle, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Function 1 — PC: "Mirror your phone". Phone: "Control your PC".
class _ConnectCard extends StatelessWidget {
  const _ConnectCard({required this.app, required this.onConnect});

  final AppController app;
  final ValueChanged<Peer> onConnect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    // Show the other kind of device: phones on the PC, PCs on the phone.
    final peers = app.peers.where((p) => p.isPhone == app.isDesktop).toList();
    final target = app.isDesktop ? 'phone' : 'PC';

    return Glass(
      radius: 30,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FunctionHeader(
            icon: app.isDesktop ? Icons.phone_iphone_rounded : Icons.laptop_windows_rounded,
            title: app.isDesktop ? 'Mirror your phone' : 'Control your PC',
            subtitle: app.isDesktop
                ? 'See and use your phone right here on your PC.'
                : 'Use this phone as a touchpad and keyboard for your PC.',
          ),
          const SizedBox(height: 18),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child: peers.isEmpty
                ? Padding(
                    key: const ValueKey('empty'),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: Column(
                        children: [
                          const SearchingRadar(),
                          const SizedBox(height: 14),
                          Text('Looking for your $target…', style: text.titleMedium),
                          const SizedBox(height: 6),
                          Text(
                            'Open PixMirror on your $target and keep both on the same Wi-Fi.',
                            textAlign: TextAlign.center,
                            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  )
                : Column(
                    key: const ValueKey('list'),
                    children: [
                      for (final p in peers)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _PeerTile(
                            peer: p,
                            paired: app.store.isTrusted(p.id),
                            onConnect: () => onConnect(p),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.paired, required this.onConnect});

  final Peer peer;
  final bool paired;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // Phones can always be asked to share; PCs must have control allowed.
    final reachable = peer.isPhone || peer.sharing;
    final status = !paired
        ? 'New device · pair once to connect'
        : peer.isPhone
            ? (peer.sharing ? 'Sharing · ready' : 'Ready · your phone will ask to share')
            : (peer.sharing ? 'Ready' : 'Control is turned off on this PC');
    final action = !paired ? 'Pair' : (peer.isPhone ? 'Mirror' : 'Control');

    return PressScale(
      scale: 0.97,
      onTap: reachable ? onConnect : null,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: scheme.secondaryContainer,
              child: Icon(deviceIcon(peer.platform), color: scheme.onSecondaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(peer.name, style: text.titleMedium, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: reachable ? const Color(0xFF34C759) : scheme.outline,
                          shape: BoxShape.circle,
                        ),
                      ),
                      Flexible(
                        child: Text(status,
                            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(onPressed: reachable ? onConnect : null, child: Text(action)),
          ],
        ),
      ),
    );
  }
}

/// Function 2 — PC: "Control this PC from your phone". Phone: "Mirror this
/// phone on your PC".
class _ShareCard extends StatelessWidget {
  const _ShareCard({required this.app, required this.onToggle});

  final AppController app;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final sharing = app.sharing;
    final viewer = app.server.viewer;

    return Glass(
      radius: 30,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FunctionHeader(
            icon: app.isDesktop ? Icons.touch_app_rounded : Icons.cast_rounded,
            title: app.isDesktop ? 'Control this PC from your phone' : 'Mirror this phone on your PC',
            subtitle: app.isDesktop
                ? 'Your paired phone can see this screen and move the pointer.'
                : 'Show this screen on your PC and use it with mouse and keyboard.',
            active: sharing,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  app.isDesktop
                      ? (sharing ? 'On · ${app.store.deviceName} is visible' : 'Off · your phone can’t connect')
                      : (sharing ? 'Sharing now' : 'Off · your PC can still ask to mirror'),
                  style: text.bodyMedium,
                ),
              ),
              Switch(value: sharing, onChanged: onToggle),
            ],
          ),
          if (!app.isDesktop && !app.phoneInputReady) ...[
            const SizedBox(height: 12),
            _Hint(
              icon: Icons.touch_app_rounded,
              text: 'Let your PC tap and type here: turn on “PixMirror remote control”.',
              action: 'Set up',
              onAction: app.openPhoneInputSettings,
            ),
          ],
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: viewer == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.cast_connected_rounded, color: scheme.onPrimaryContainer),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${viewer.name} is ${app.isDesktop ? 'controlling this PC' : 'mirroring this phone'}',
                              style: text.bodyMedium?.copyWith(color: scheme.onPrimaryContainer),
                            ),
                          ),
                          TextButton(onPressed: app.server.disconnectViewer, child: const Text('Disconnect')),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, required this.action, required this.onAction});

  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onTertiaryContainer)),
          ),
          TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );
  }
}
