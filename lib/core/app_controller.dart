import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/android_host.dart';
import '../platform/screen_host.dart';
import '../platform/windows_host.dart';
import 'discovery.dart';
import 'host_server.dart';
import 'remote_session.dart';
import 'store.dart';

/// App-wide state: discovery, our own sharing, and the session we view.
class AppController extends ChangeNotifier {
  AppController(this.store, {ScreenHost? host, bool? desktop})
      : host = host ?? (Platform.isAndroid ? AndroidHost() : WindowsHost()),
        // ignore: prefer_initializing_formals
        _desktop = desktop;

  final bool? _desktop;

  final Store store;
  final ScreenHost host;
  late final Discovery discovery;
  late final HostServer server;

  List<Peer> peers = const [];
  RemoteSession? session;
  bool phoneInputReady = false;

  /// Fires when a paired device that is sharing comes into range — this is
  /// what drives the "iPhone is nearby" style popup.
  final _nearby = StreamController<Peer>.broadcast();
  Stream<Peer> get nearby => _nearby.stream;
  final Set<String> _announcedNearby = {};

  bool get isDesktop => _desktop ?? !Platform.isAndroid;

  /// Whether this device is currently visible as connectable.
  bool get sharing => isDesktop ? store.allowControl && host.running : host.running;

  /// Wires up state without touching the network or platform services,
  /// for UI previews and screenshots.
  @visibleForTesting
  void initOffline({List<Peer> peers = const []}) {
    server = HostServer(store: store, host: host, accepting: () => true)..addListener(notifyListeners);
    discovery = Discovery(id: store.deviceId, name: () => store.deviceName, platform: Store.platform, isSharing: () => sharing);
    this.peers = peers;
  }

  Future<void> init() async {
    if (Platform.isAndroid) {
      await native.invokeMethod('acquireMulticast');
      await native.invokeMethod('requestNotifications');
      // Stay discoverable while PixMirror is in the background.
      await native.invokeMethod('startPresence');
      phoneInputReady = await host.inputAvailable();
    } else {
      await host.start(store.quality);
    }

    // A phone is always reachable while the app runs; if it is not sharing
    // yet, the PC's request pops up here and the user starts it with a tap.
    server = HostServer(
      store: store,
      host: host,
      accepting: () => isDesktop ? store.allowControl : true,
    )
      ..addListener(notifyListeners);
    await server.listen();

    discovery = Discovery(
      id: store.deviceId,
      name: () => store.deviceName,
      platform: Store.platform,
      isSharing: () => sharing,
    );
    discovery.changes.listen(_onPeers);
    await discovery.start();

    host.stopped.listen((_) {
      server.stopAll();
      discovery.announce();
      notifyListeners();
    });
    store.addListener(() {
      host.configure(store.quality);
      discovery.announce();
      notifyListeners();
    });
  }

  void _onPeers(List<Peer> list) {
    peers = list;
    for (final p in list) {
      // Paired phones count as ready even when not sharing: connecting asks
      // the phone to start, like iPhone Mirroring.
      final ready = store.isTrusted(p.id) && (p.sharing || p.isPhone);
      if (ready && _announcedNearby.add(p.id)) {
        if (session == null) _nearby.add(p);
      } else if (!ready) {
        _announcedNearby.remove(p.id);
      }
    }
    _announcedNearby.removeWhere((id) => !list.any((p) => p.id == id));
    notifyListeners();
  }

  Future<bool> setSharing(bool on) async {
    if (isDesktop) {
      store.allowControl = on;
      if (!on) server.stopAll();
    } else if (on) {
      final ok = await host.start(store.quality);
      if (!ok) return false;
    } else {
      server.stopAll();
      await host.stop();
    }
    await discovery.announce();
    notifyListeners();
    return true;
  }

  /// User tapped "Start sharing" on an incoming mirror request.
  Future<void> acceptShareRequest() async {
    if (Platform.isAndroid) native.invokeMethod('clearRequest');
    final ok = host.running || await setSharing(true);
    server.answerShare(ok);
  }

  void declineShareRequest() {
    if (Platform.isAndroid) native.invokeMethod('clearRequest');
    server.answerShare(false);
  }

  Future<void> refreshPhoneInput() async {
    if (!Platform.isAndroid) return;
    phoneInputReady = await host.inputAvailable();
    notifyListeners();
  }

  Future<void> openPhoneInputSettings() => native.invokeMethod('openInputSettings');

  RemoteSession connect(Peer peer) {
    session?.close();
    session?.dispose();
    final s = RemoteSession(peer: peer, store: store);
    session = s;
    s.connect();
    notifyListeners();
    return s;
  }

  void endSession() {
    final s = session;
    session = null;
    s?.close();
    // Let the viewer route finish animating before releasing images.
    Future.delayed(const Duration(seconds: 1), () => s?.dispose());
    notifyListeners();
  }

  @override
  void dispose() {
    discovery.dispose();
    server.shutdown();
    _nearby.close();
    super.dispose();
  }
}
