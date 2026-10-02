import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/screen_host.dart';
import 'protocol.dart';
import 'security.dart';
import 'store.dart';

/// A viewer asking to pair. The UI shows [code] and resolves [decision].
class PairRequest {
  PairRequest(this.id, this.name, this.platform, this.code);
  final String id;
  final String name;
  final String platform;
  final String code;
  final decision = Completer<bool>();
}

/// A paired PC asked to mirror this phone while sharing was off. The UI asks
/// the user to start sharing and resolves [decision].
class ShareRequest {
  ShareRequest(this.name);
  final String name;
  final decision = Completer<bool>();
}

class ActiveViewer {
  const ActiveViewer(this.id, this.name, this.platform);
  final String id;
  final String name;
  final String platform;
}

/// Accepts viewers over WebSocket, authenticates them and streams frames.
/// One viewer at a time keeps things simple and private.
class HostServer extends ChangeNotifier {
  HostServer({required this.store, required this.host, required this.accepting});

  final Store store;
  final ScreenHost host;
  final bool Function() accepting;

  HttpServer? _server;
  _HostSession? _session;
  PairRequest? pendingPair;
  ShareRequest? shareRequest;

  ActiveViewer? get viewer => _session?.viewer;

  Future<void> listen() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, kHostPort, shared: true);
    _server!.listen((request) async {
      if (request.uri.path != '/ws' || !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(request);
      ws.pingInterval = const Duration(seconds: 4);
      _HostSession(this, ws).run();
    });
  }

  void answerPair(bool allow) {
    final p = pendingPair;
    if (p != null && !p.decision.isCompleted) p.decision.complete(allow);
  }

  void answerShare(bool started) {
    final r = shareRequest;
    if (r != null && !r.decision.isCompleted) r.decision.complete(started);
  }

  void disconnectViewer() => _session?.close('Disconnected by host');

  /// Called when sharing is turned off.
  void stopAll() {
    answerPair(false);
    answerShare(false);
    disconnectViewer();
  }

  Future<void> shutdown() async {
    stopAll();
    await _server?.close(force: true);
  }

  void _changed() => notifyListeners();
}

class _HostSession {
  _HostSession(this.server, this.ws);

  final HostServer server;
  final WebSocket ws;
  ActiveViewer? viewer;

  var _stage = 0; // 0 hello, 1 auth, 2 pairing, 3 live, 4 closed
  String? _nonce;
  String? _peerId;
  String? _peerName;
  String? _peerPlatform;
  int _inFlight = 0;
  Completer<void>? _ackWaiter;
  bool _forceNext = true;
  Timer? _cursorTimer;
  Timer? _helloTimeout;
  CursorState? _lastCursor;

  ScreenHost get host => server.host;
  Store get store => server.store;

  void send(String type, [Map<String, Object?> fields = const {}]) {
    if (_stage == 4) return;
    try {
      ws.add(encodeMsg(type, fields));
    } catch (_) {}
  }

  void run() {
    _helloTimeout = Timer(const Duration(seconds: 10), () {
      if (_stage < 3 && _stage != 2) close('Handshake timed out');
    });
    ws.listen(_onMessage, onDone: _cleanup, onError: (_) => _cleanup());
  }

  void close(String reason) {
    if (_stage == 4) return;
    if (_stage < 3) send(Msg.denied, {'reason': reason});
    if (_stage == 3) send(Msg.bye, {'reason': reason});
    ws.close();
    _cleanup();
  }

  void _cleanup() {
    if (_stage == 4) return;
    _stage = 4;
    // Release the session first: anything below failing must never leave
    // the host stuck thinking a viewer is still connected.
    if (identical(server._session, this)) {
      server._session = null;
      server._changed();
    }
    _helloTimeout?.cancel();
    _cursorTimer?.cancel();
    final waiter = _ackWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    final share = _shareRequest;
    if (share != null && identical(server.shareRequest, share)) {
      if (!share.decision.isCompleted) share.decision.complete(false);
      server.shareRequest = null;
      server._changed();
    }
    final pair = server.pendingPair;
    if (pair != null && pair.id == _peerId) {
      if (!pair.decision.isCompleted) pair.decision.complete(false);
      server.pendingPair = null;
      server._changed();
    }
  }

  void _onMessage(dynamic data) {
    final m = decodeMsg(data);
    if (m == null) return;
    switch (_stage) {
      case 0:
        if (m['t'] == Msg.hello) _onHello(m);
      case 1:
        if (m['t'] == Msg.auth) _onAuth(m);
      case 3:
        _onLive(m);
    }
  }

  void _onHello(Map<String, dynamic> m) {
    _peerId = m['id'] as String?;
    _peerName = (m['name'] as String?) ?? 'Unknown device';
    _peerPlatform = (m['platform'] as String?) ?? 'unknown';
    if (_peerId == null) return close('Bad hello');
    // Phones accept while the app is alive and ask their user to start
    // sharing on demand; PCs accept only while "Allow control" is on.
    if (!server.accepting()) return close('Sharing is off');
    final existing = server._session;
    // The same device reconnecting (e.g. after Wi-Fi dropped) replaces its
    // old session once it authenticates; a different device is refused.
    if (existing != null && existing.viewer?.id != _peerId) {
      return close('${existing.viewer?.name ?? 'Another device'} is already connected');
    }
    if (store.isTrusted(_peerId!)) {
      _stage = 1;
      _nonce = Store.randomToken(16);
      send(Msg.challenge, {'nonce': _nonce});
    } else {
      _pair();
    }
  }

  void _onAuth(Map<String, dynamic> m) {
    final trusted = store.trustedById(_peerId!);
    final mac = m['mac'] as String? ?? '';
    if (trusted == null || !constantTimeEquals(mac, signNonce(trusted.secret, _nonce!))) {
      return close('auth');
    }
    if (trusted.name != _peerName) {
      trusted.name = _peerName!;
      store.trust(trusted);
    }
    _goLive();
  }

  Future<void> _pair() async {
    if (server.pendingPair != null) return close('Another pairing is in progress');
    _stage = 2;
    final request = PairRequest(_peerId!, _peerName!, _peerPlatform!, pairingCode());
    server.pendingPair = request;
    server._changed();
    send(Msg.pairing, {'code': request.code});

    final allowed = await request.decision.future
        .timeout(const Duration(seconds: 60), onTimeout: () => false);
    if (identical(server.pendingPair, request)) {
      server.pendingPair = null;
      server._changed();
    }
    if (_stage == 4) return;
    if (!allowed) return close('Request declined');

    final secret = Store.randomToken(32);
    store.trust(TrustedDevice(
        id: _peerId!, name: _peerName!, platform: _peerPlatform!, secret: secret));
    send(Msg.paired, {
      'secret': secret,
      'id': store.deviceId,
      'name': store.deviceName,
      'platform': Store.platform,
    });
    final other = server._session;
    if (other != null && other.viewer?.id != _peerId) return close('Another device connected first');
    _goLive();
  }

  ShareRequest? _shareRequest;

  Future<void> _goLive() async {
    _helloTimeout?.cancel();
    if (!host.running) {
      _stage = 2;
      final request = ShareRequest(_peerName!);
      _shareRequest = request;
      server.shareRequest = request;
      server._changed();
      send(Msg.waiting, {'reason': 'share'});
      final started = await request.decision.future
          .timeout(const Duration(seconds: 90), onTimeout: () => false);
      if (identical(server.shareRequest, request)) {
        server.shareRequest = null;
        server._changed();
      }
      if (_stage == 4) return;
      if (!started || !host.running) {
        return close("Sharing wasn't started on ${store.deviceName}");
      }
    }
    final previous = server._session;
    if (previous != null && !identical(previous, this)) previous.close('Reconnected');
    _stage = 3;
    viewer = ActiveViewer(_peerId!, _peerName!, _peerPlatform!);
    server._session = this;
    server._changed();

    final info = await host.screenInfo();
    final (w, h) = host.screenSize;
    send(Msg.welcome, {
      'device': info,
      'id': store.deviceId,
      'name': store.deviceName,
      'platform': host.platform,
      'w': w,
      'h': h,
      'monitors': host.monitorCount,
      'monitor': host.monitor,
      'input': await host.inputAvailable(),
    });

    if (host.cursor() != null) {
      _cursorTimer = Timer.periodic(const Duration(milliseconds: 33), (_) => _sendCursor());
    }
    _frameLoop();
  }

  void _sendCursor() {
    final c = host.cursor();
    if (c == null) return;
    final last = _lastCursor;
    if (last != null && last.x == c.x && last.y == c.y && last.kind == c.kind) return;
    _lastCursor = c;
    send(Msg.cursor, {'x': c.x, 'y': c.y, 'k': c.kind.index});
  }

  Future<void> _frameLoop() async {
    try {
      await _streamFrames();
    } catch (_) {
      // Socket died mid-send; fall through to cleanup.
    }
    if (_stage != 4) close('Stream error');
  }

  Future<void> _streamFrames() async {
    final frameGap = Duration(milliseconds: 1000 ~/ store.quality.fps);
    final clock = Stopwatch()..start();
    while (_stage == 3) {
      // At most two frames in flight: enough to hide network latency,
      // few enough that the picture never lags behind reality.
      while (_inFlight >= 2 && _stage == 3) {
        _ackWaiter = Completer<void>();
        await _ackWaiter!.future;
      }
      if (_stage != 3) break;
      final force = _forceNext;
      _forceNext = false;
      final frame = await host.nextFrame(force: force);
      if (_stage != 3) break;
      if (frame == null) {
        // Nothing changed: poll again soon so the next change goes out
        // with minimal delay (desktop duplication makes polling cheap).
        await Future.delayed(const Duration(milliseconds: 8));
        continue;
      }
      _inFlight++;
      ws.add(encodeFrame(frame.jpeg, frame.width, frame.height));
      final wait = frameGap - clock.elapsed;
      if (wait > Duration.zero) await Future.delayed(wait);
      clock.reset();
    }
  }

  void _onLive(Map<String, dynamic> m) {
    switch (m['t']) {
      case Msg.ack:
        if (_inFlight > 0) _inFlight--;
        final w = _ackWaiter;
        if (w != null && !w.isCompleted) w.complete();
      case Msg.config:
        final mon = m['mon'];
        if (mon is int && mon >= 0 && mon < host.monitorCount && mon != host.monitor) {
          host.monitor = mon;
          final (w, h) = host.screenSize;
          send(Msg.screen, {'w': w, 'h': h, 'monitor': mon});
        }
        _forceNext = true;
      case Msg.bye:
        ws.close();
        _cleanup();
      default:
        host.handleInput(m);
    }
  }
}
