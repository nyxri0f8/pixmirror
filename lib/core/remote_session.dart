import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../platform/screen_host.dart';
import 'discovery.dart';
import 'protocol.dart';
import 'security.dart';
import 'store.dart';

enum SessionPhase { connecting, awaitingApproval, awaitingShare, live, closed }

/// Viewer side of a mirroring session.
class RemoteSession extends ChangeNotifier {
  RemoteSession({required this.peer, required this.store});

  final Peer peer;
  final Store store;

  SessionPhase phase = SessionPhase.connecting;
  String? pairCode;
  String? error;
  late String hostName = peer.name;
  late String hostPlatform = peer.platform;
  int screenWidth = 0;
  int screenHeight = 0;
  int monitors = 1;
  int monitor = 0;
  bool inputAvailable = true;

  /// Phone geometry from the host: w, h, corner (px), cutouts [l,t,r,b,...].
  Map<String, dynamic> device = const {};

  /// Latest decoded frame. Separate notifiers keep 30 fps repaints cheap.
  final frame = ValueNotifier<ui.Image?>(null);
  final cursor = ValueNotifier<CursorState?>(null);
  final fps = ValueNotifier<int>(0);

  WebSocket? _ws;
  bool _decoding = false;
  Frame? _queued;
  int _framesThisSecond = 0;
  Timer? _fpsTimer;

  bool get isTouchHost => hostPlatform == 'android';

  Future<void> connect() async {
    try {
      final ws = await WebSocket.connect('ws://${peer.address.address}:${peer.port}/ws')
          .timeout(const Duration(seconds: 6));
      ws.pingInterval = const Duration(seconds: 4);
      _ws = ws;
      ws.listen(_onData, onDone: () => _end(error ?? 'Connection closed'),
          onError: (_) => _end('Connection lost'));
      send(Msg.hello, {
        'v': kProtocolVersion,
        'id': store.deviceId,
        'name': store.deviceName,
        'platform': Store.platform,
      });
    } catch (_) {
      _end("Couldn't reach ${peer.name}. Make sure both devices are on the same Wi-Fi.");
    }
  }

  void send(String type, [Map<String, Object?> fields = const {}]) {
    if (phase == SessionPhase.closed) return;
    _ws?.add(encodeMsg(type, fields));
  }

  void _onData(dynamic data) {
    if (data is List<int>) {
      final f = decodeFrame(data);
      if (f != null) _enqueue(f);
      return;
    }
    final m = decodeMsg(data);
    if (m == null) return;
    switch (m['t']) {
      case Msg.challenge:
        final trusted = store.trustedById(peer.id);
        if (trusted == null) return _end('Pairing data missing. Try again.');
        send(Msg.auth, {'mac': signNonce(trusted.secret, m['nonce'] as String)});
      case Msg.pairing:
        pairCode = m['code'] as String;
        phase = SessionPhase.awaitingApproval;
        notifyListeners();
      case Msg.waiting:
        phase = SessionPhase.awaitingShare;
        notifyListeners();
      case Msg.paired:
        store.trust(TrustedDevice(
          id: m['id'] as String,
          name: m['name'] as String,
          platform: m['platform'] as String,
          secret: m['secret'] as String,
        ));
      case Msg.welcome:
        hostName = m['name'] as String;
        hostPlatform = m['platform'] as String;
        screenWidth = m['w'] as int;
        screenHeight = m['h'] as int;
        monitors = m['monitors'] as int? ?? 1;
        monitor = m['monitor'] as int? ?? 0;
        inputAvailable = m['input'] != false;
        device = (m['device'] as Map?)?.cast<String, dynamic>() ?? const {};
        phase = SessionPhase.live;
        _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          fps.value = _framesThisSecond;
          _framesThisSecond = 0;
        });
        notifyListeners();
      case Msg.screen:
        screenWidth = m['w'] as int;
        screenHeight = m['h'] as int;
        monitor = m['monitor'] as int;
        notifyListeners();
      case Msg.cursor:
        cursor.value = CursorState(
          (m['x'] as num).toDouble(),
          (m['y'] as num).toDouble(),
          CursorKind.values[(m['k'] as int).clamp(0, 4)],
        );
      case Msg.denied:
        final reason = m['reason'] as String? ?? 'Declined';
        if (reason == 'auth') {
          // The other side forgot us; drop our half so the next try re-pairs.
          store.forget(peer.id);
          error = '${peer.name} no longer trusts this device. Connect again to re-pair.';
        } else {
          error = reason;
        }
      case Msg.bye:
        error = m['reason'] as String?;
    }
  }

  void _enqueue(Frame f) {
    if (_decoding) {
      // Newer frame replaces any undecoded one; still ack the dropped frame.
      if (_queued != null) send(Msg.ack);
      _queued = f;
      return;
    }
    _decode(f);
  }

  Future<void> _decode(Frame f) async {
    _decoding = true;
    try {
      final codec = await ui.instantiateImageCodec(f.jpeg);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      if (phase == SessionPhase.closed) {
        image.dispose();
      } else {
        final old = frame.value;
        frame.value = image;
        old?.dispose();
        _framesThisSecond++;
      }
    } catch (_) {}
    send(Msg.ack);
    _decoding = false;
    final next = _queued;
    _queued = null;
    if (next != null) _decode(next);
  }

  // ---- Input helpers -------------------------------------------------------

  void moveTo(double x, double y) => send(Msg.move, {'x': x, 'y': y});
  void button(int b, bool down) => send(Msg.button, {'b': b, 'd': down});
  void click([int b = 0]) {
    button(b, true);
    button(b, false);
  }

  void wheel(double dx, double dy) => send(Msg.wheel, {'dx': dx, 'dy': dy});
  void touchDown(double x, double y) => send(Msg.touchDown, {'x': x, 'y': y});
  void touchMove(double x, double y) => send(Msg.touchMove, {'x': x, 'y': y});
  void touchUp(double x, double y) => send(Msg.touchUp, {'x': x, 'y': y});
  void touch(List<double> points, int ms) => send(Msg.touch, {'p': points, 'ms': ms});
  void nav(String action) => send(Msg.nav, {'a': action});
  void typeText(String s) => send(Msg.text, {'s': s});
  void key(String k, [List<String> mods = const []]) => send(Msg.key, {'k': k, 'm': mods});

  void selectMonitor(int index) => send(Msg.config, {'mon': index});

  void close() {
    send(Msg.bye);
    _ws?.close();
    _end(null);
  }

  void _end(String? reason) {
    if (phase == SessionPhase.closed) return;
    error ??= reason;
    phase = SessionPhase.closed;
    _fpsTimer?.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _ws?.close();
    _fpsTimer?.cancel();
    frame.value?.dispose();
    frame.dispose();
    cursor.dispose();
    fps.dispose();
    super.dispose();
  }
}
