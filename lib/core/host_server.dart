import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/screen_host.dart';
import 'input_guard.dart';
import 'protocol.dart';
import 'secure_channel.dart';
import 'store.dart';

/// A viewer asking to pair. The UI shows [code] — the handshake's short
/// authentication string — and resolves [decision].
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

/// Sliding-window limits per remote address, so a hostile device on the LAN
/// cannot flood pairing prompts or brute-force its way in.
class RateLimiter {
  RateLimiter({this.connectionsPerMinute = 20, this.pairingsPer10Min = 4, this.failuresBeforeLockout = 5});

  final int connectionsPerMinute;
  final int pairingsPer10Min;
  final int failuresBeforeLockout;
  final _connections = <String, List<DateTime>>{};
  final _pairings = <String, List<DateTime>>{};
  final _failures = <String, List<DateTime>>{};

  bool _hit(Map<String, List<DateTime>> map, String key, Duration window, int max, {bool record = true}) {
    final now = DateTime.now();
    final list = map.putIfAbsent(key, () => [])..removeWhere((t) => now.difference(t) > window);
    if (list.length >= max) return false;
    if (record) list.add(now);
    return true;
  }

  bool allowConnection(String ip) =>
      !isLockedOut(ip) && _hit(_connections, ip, const Duration(minutes: 1), connectionsPerMinute);
  bool allowPairing(String ip) => _hit(_pairings, ip, const Duration(minutes: 10), pairingsPer10Min);
  void recordFailure(String ip) => _hit(_failures, ip, const Duration(minutes: 10), 1 << 30);
  bool isLockedOut(String ip) =>
      !_hit(_failures, ip, const Duration(minutes: 10), failuresBeforeLockout, record: false);
}

/// Accepts viewers over WebSocket, authenticates them and streams frames.
/// One viewer at a time keeps things simple and private.
class HostServer extends ChangeNotifier {
  HostServer({
    required this.store,
    required this.host,
    required this.accepting,
    this.port = kHostPort,
    InternetAddress? bindAddress,
    this.allowAddress = isLocalNetwork,
    RateLimiter? limiter,
  })  : limiter = limiter ?? RateLimiter(),
        bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  final InternetAddress bindAddress;

  final Store store;
  final ScreenHost host;
  final bool Function() accepting;
  final int port;

  /// Only devices on the local network may connect.
  final bool Function(InternetAddress) allowAddress;
  final RateLimiter limiter;

  HttpServer? _server;
  _HostSession? _session;
  PairRequest? pendingPair;
  ShareRequest? shareRequest;

  /// Security-relevant events, for tests and diagnostics.
  final events = StreamController<String>.broadcast();

  ActiveViewer? get viewer => _session?.viewer;
  int get boundPort => _server?.port ?? port;

  Future<void> listen() async {
    _server = await HttpServer.bind(bindAddress, port, shared: true);
    _server!
      ..idleTimeout = const Duration(seconds: 15)
      ..serverHeader = null;
    _server!.listen((request) async {
      final remote = request.connectionInfo?.remoteAddress;
      final ip = remote?.address ?? '?';
      if (remote == null || !allowAddress(remote)) {
        events.add('rejected non-local $ip');
        return _refuse(request, HttpStatus.forbidden);
      }
      if (!limiter.allowConnection(ip)) {
        events.add('rate-limited $ip');
        return _refuse(request, HttpStatus.tooManyRequests);
      }
      if (request.uri.path != '/ws' || !WebSocketTransformer.isUpgradeRequest(request)) {
        return _refuse(request, HttpStatus.notFound);
      }
      try {
        final ws = await WebSocketTransformer.upgrade(request);
        ws.pingInterval = const Duration(seconds: 4);
        _HostSession(this, ws, ip).run();
      } catch (_) {}
    });
  }

  void _refuse(HttpRequest r, int status) {
    try {
      r.response
        ..statusCode = status
        ..close();
    } catch (_) {}
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
  _HostSession(this.server, this.ws, this.ip);

  final HostServer server;
  final WebSocket ws;
  final String ip;
  ActiveViewer? viewer;
  SecureChannel? _ch;

  var _stage = 0; // 0 handshake, 2 waiting (pair/share), 3 live, 4 closed
  String? _peerId;
  String? _peerName;
  String? _peerPlatform;
  int _inFlight = 0;
  Completer<void>? _ackWaiter;
  bool _forceNext = true;
  Timer? _cursorTimer;
  CursorState? _lastCursor;
  ShareRequest? _shareRequest;

  ScreenHost get host => server.host;
  Store get store => server.store;

  void send(String type, [Map<String, Object?> fields = const {}]) {
    if (_stage == 4) return;
    _ch?.sendJson({'t': type, ...fields});
  }

  Future<void> run() async {
    final incoming = StreamIterator<dynamic>(ws);
    try {
      final hs = await handshake(
        ws: ws,
        incoming: incoming,
        identity: store.identity,
        initiator: false,
        name: store.deviceName,
        platform: Store.platform,
      );
      _ch = hs.channel..maxMessageBytes = 64 * 1024; // viewers only send input
      _peerId = hs.peerId;
      _peerName = hs.peerName;
      _peerPlatform = hs.peerPlatform;
      await _admit(hs);
      if (_stage == 4) return;
      await for (final m in _ch!.messages()) {
        if (_stage == 4) break;
        if (m is Map<String, dynamic>) _onMessage(m);
      }
    } on SecurityException catch (e) {
      server.limiter.recordFailure(ip);
      server.events.add('security: ${e.message} from $ip');
    } catch (_) {
      // Timeout or socket error.
    }
    if (_stage != 4) close('Connection closed');
  }

  void close(String reason) {
    if (_stage == 4) return;
    if (_stage < 3) send(Msg.denied, {'reason': reason});
    if (_stage == 3) send(Msg.bye, {'reason': reason});
    _stage = 4;
    // Let the final encrypted message flush before closing.
    Future.delayed(const Duration(milliseconds: 50), () => ws.close());
    _cleanup();
  }

  void _cleanup() {
    _stage = 4;
    // Release the session first: anything below failing must never leave
    // the host stuck thinking a viewer is still connected.
    if (identical(server._session, this)) {
      server._session = null;
      server._changed();
    }
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

  Future<void> _admit(HandshakeResult hs) async {
    // Phones accept while the app is alive and ask their user to start
    // sharing on demand; PCs accept only while "Allow control" is on.
    if (!server.accepting()) return close('Sharing is off');
    final existing = server._session;
    if (existing != null && existing.viewer?.id != _peerId) {
      return close('${existing.viewer?.name ?? 'Another device'} is already connected');
    }

    final trusted = store.trustedById(_peerId!);
    final pinned = trusted != null &&
        constantTimeBytesEqual(base64.decode(trusted.publicKey), hs.peerPublicKey);
    if (pinned) {
      if (trusted.name != _peerName) {
        trusted.name = _peerName!;
        store.trust(trusted);
      }
      server.events.add('trusted $_peerId');
      return _goLive();
    }

    // Unknown key: numeric-comparison pairing using the handshake's SAS.
    if (!server.limiter.allowPairing(ip)) {
      server.events.add('pairing rate-limited $ip');
      return close('Too many pairing attempts. Try again later.');
    }
    if (server.pendingPair != null) return close('Another pairing is in progress');
    _stage = 2;
    final request = PairRequest(_peerId!, _peerName!, _peerPlatform!, hs.sas);
    server.pendingPair = request;
    server._changed();
    server.events.add('pairing $_peerId');
    send(Msg.pairing, {'code': hs.sas});

    final allowed = await request.decision.future
        .timeout(const Duration(seconds: 60), onTimeout: () => false);
    if (identical(server.pendingPair, request)) {
      server.pendingPair = null;
      server._changed();
    }
    if (_stage == 4) return;
    if (!allowed) return close('Request declined');

    // No secret crosses the network: each side simply pins the other's key.
    store.trust(TrustedDevice(
      id: _peerId!,
      name: _peerName!,
      platform: _peerPlatform!,
      publicKey: base64.encode(hs.peerPublicKey),
    ));
    send(Msg.paired, {});
    final other = server._session;
    if (other != null && other.viewer?.id != _peerId) return close('Another device connected first');
    await _goLive();
  }

  Future<void> _goLive() async {
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
      await _ch!.sendFrame(encodeFrame(frame.jpeg, frame.width, frame.height));
      final wait = frameGap - clock.elapsed;
      if (wait > Duration.zero) await Future.delayed(wait);
      clock.reset();
    }
  }

  void _onMessage(Map<String, dynamic> m) {
    // Nothing but control traffic is accepted until the session is live.
    if (_stage != 3) return;
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
        close('Viewer left');
      default:
        final safe = sanitizeInput(m, host.platform);
        if (safe != null) host.handleInput(safe);
    }
  }
}
