// Security test suite: runs real attacks against the real HostServer over
// loopback sockets, then benchmarks the secure transport.
//
//   flutter test test/security_test.dart
//
// Results are written to build/security/report.json; tools/make_security_chart.py
// turns them into docs/security-benchmark.png.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixmirror/core/host_server.dart';
import 'package:pixmirror/core/input_guard.dart';
import 'package:pixmirror/core/protocol.dart';
import 'package:pixmirror/core/secure_channel.dart';
import 'package:pixmirror/core/store.dart';
import 'package:pixmirror/platform/screen_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Screen host stand-in: serves a 100 KB "frame" and records applied input.
class FakeHost extends ScreenHost {
  final inputs = <Map<String, dynamic>>[];
  final _frame = Uint8List.fromList(List.generate(100 * 1024, (i) => (i * 31) & 0xFF));

  @override
  String get platform => 'windows';
  @override
  bool get running => true;
  @override
  Stream<void> get stopped => const Stream.empty();
  @override
  Future<bool> start(QualityPreset quality) async => true;
  @override
  Future<void> stop() async {}
  @override
  void configure(QualityPreset quality) {}
  @override
  Future<Frame?> nextFrame({bool force = false}) async => Frame(1280, 800, _frame);
  @override
  (int, int) get screenSize => (1920, 1080);
  @override
  Future<bool> inputAvailable() async => true;
  @override
  void handleInput(Map<String, dynamic> msg) => inputs.add(msg);
}

final results = <Map<String, Object?>>[];
final bench = <String, Object?>{};

void record(String id, String title, String threat, bool passed, [String detail = '']) =>
    results.add({'id': id, 'title': title, 'threat': threat, 'passed': passed, 'detail': detail});

late Store store;
late FakeHost fake;

Future<HostServer> startServer({RateLimiter? limiter, bool Function()? approve}) async {
  final server = HostServer(
    store: store,
    host: fake,
    accepting: () => true,
    port: 0,
    bindAddress: InternetAddress.loopbackIPv4,
    limiter: limiter ?? RateLimiter(connectionsPerMinute: 10000, pairingsPer10Min: 10000),
  );
  if (approve != null) {
    server.addListener(() {
      if (server.pendingPair != null) server.answerPair(approve());
    });
  }
  await server.listen();
  return server;
}

class Client {
  Client(this.ws, this.hs);
  final WebSocket ws;
  final HandshakeResult hs;
  SecureChannel get ch => hs.channel;

  /// Reads until a JSON message of [type] (frames are acked and skipped).
  Future<Map<String, dynamic>?> until(String type, {Duration timeout = const Duration(seconds: 5)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final Object m;
      try {
        m = await ch.receive().timeout(end.difference(DateTime.now()));
      } catch (_) {
        return null;
      }
      if (m is Uint8List) {
        ch.sendJson({'t': Msg.ack});
        continue;
      }
      if (m is Map<String, dynamic> && m['t'] == type) return m;
    }
    return null;
  }

  /// True once the server has closed the connection.
  Future<bool> closedWithin(Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      try {
        final m = await ch.receive().timeout(end.difference(DateTime.now()));
        if (m is Uint8List) ch.sendJson({'t': Msg.ack});
      } on StateError {
        return true;
      } on TimeoutException {
        return false;
      } catch (_) {
        return true;
      }
    }
    return false;
  }
}

Future<Client> dial(int port, Identity id, {String name = 'Tester'}) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
  final hs = await handshake(
    ws: ws,
    incoming: StreamIterator<dynamic>(ws),
    identity: id,
    initiator: true,
    name: name,
    platform: 'android',
  );
  return Client(ws, hs);
}

Future<Client> pairedLiveClient(HostServer server, Identity id) async {
  final c = await dial(server.boundPort, id);
  final welcome = await c.until(Msg.welcome);
  expect(welcome, isNotNull, reason: 'session should go live');
  return c;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    store = await Store.load(defaultName: 'TestHost');
  });
  setUp(() => fake = FakeHost());

  tearDownAll(() async {
    final dir = Directory('build/security')..createSync(recursive: true);
    File('${dir.path}/report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'generated': DateTime.now().toIso8601String(),
      'dart': Platform.version.split(' ').first,
      'os': Platform.operatingSystemVersion,
      'tests': results,
      'benchmarks': bench,
    }));
  });

  test('legacy plaintext (v1) clients are refused', () async {
    final server = await startServer(approve: () => true);
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/ws');
    ws.add(jsonEncode({'t': 'hello', 'v': 1, 'id': 'x', 'name': 'old', 'platform': 'android'}));
    final closed = await ws.toList().timeout(const Duration(seconds: 5)).then((_) => true, onError: (_) => false);
    final ok = closed && fake.inputs.isEmpty && server.pendingPair == null;
    record('plaintext', 'Plaintext / downgrade attempt refused', 'Downgrade to an unencrypted protocol', ok);
    expect(ok, isTrue);
    await server.shutdown();
  });

  test('pairing codes match end-to-end (no one in the middle)', () async {
    String? hostCode;
    final server = await startServer();
    server.addListener(() {
      final p = server.pendingPair;
      if (p != null) {
        hostCode = p.code;
        server.answerPair(true);
      }
    });
    final id = await Identity.generate();
    final c = await dial(server.boundPort, id);
    await c.until(Msg.welcome);
    // After approval the host has pinned the viewer's public key.
    final pinned = store.isTrusted(await fingerprintOf(id.publicKey));
    final ok = hostCode != null && hostCode == c.hs.sas && pinned;
    record('sas', 'Pairing code identical on both screens', 'Pairing without a shared secret on the wire', ok,
        'code ${c.hs.sas}');
    expect(ok, isTrue);
    await c.ch.close();
    await server.shutdown();
  });

  test('man-in-the-middle relay shows different codes and a wrong identity', () async {
    String? hostCode;
    final server = await startServer();
    server.addListener(() {
      final p = server.pendingPair;
      if (p != null) hostCode = p.code;
    });
    final realHostId = store.deviceId;
    final attacker = await Identity.generate();
    final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final victimSas = Completer<String>();
    relay.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      // Attacker terminates the victim's connection...
      unawaited(handshake(
        ws: ws,
        incoming: StreamIterator<dynamic>(ws),
        identity: attacker,
        initiator: false,
        name: 'TestHost',
        platform: 'windows',
      ).then((hs) => victimSas.complete(hs.sas), onError: (_) {}));
    });
    final victim = await Identity.generate();
    final c = await dial(relay.port, victim);
    // ...and opens its own to the real host.
    await dial(server.boundPort, attacker);
    await Future.delayed(const Duration(milliseconds: 300));
    final sasViewer = c.hs.sas;
    final identityMismatch = c.hs.peerId != realHostId;
    final ok = hostCode != null && hostCode != sasViewer && identityMismatch;
    record('mitm', 'Man-in-the-middle detected', 'Attacker relaying between phone and PC', ok,
        'viewer saw $sasViewer, host saw $hostCode; identity mismatch: $identityMismatch');
    expect(ok, isTrue);
    server.answerPair(false);
    await relay.close(force: true);
    await server.shutdown();
  });

  test('impersonating a paired device without its private key fails', () async {
    final server = await startServer(approve: () => true);
    final real = await Identity.generate();
    (await pairedLiveClient(server, real)).ch.close();
    await Future.delayed(const Duration(milliseconds: 100));
    // Attacker claims the real device's public key but has a different key.
    final forged = await Identity.forged(await X25519().newKeyPair(), real.publicKey);
    var failed = false;
    try {
      final c = await dial(server.boundPort, forged);
      failed = await c.closedWithin(const Duration(seconds: 3));
    } catch (_) {
      failed = true;
    }
    final ok = failed && fake.inputs.isEmpty;
    record('impersonation', 'Stolen device id is useless without its key', 'Spoofing a trusted phone', ok);
    expect(ok, isTrue);
    await server.shutdown();
  });

  test('tampered messages kill the session', () async {
    final server = await startServer(approve: () => true);
    final c = await pairedLiveClient(server, await Identity.generate());
    c.ch.debugOnSend = (bytes) => bytes[0] ^= 0x01; // flip one bit in flight
    c.ch.sendJson({'t': Msg.move, 'x': 0.5, 'y': 0.5});
    final closed = await c.closedWithin(const Duration(seconds: 3));
    final ok = closed && fake.inputs.isEmpty;
    record('tamper', 'Tampered message rejected', 'Modifying traffic in transit', ok);
    expect(ok, isTrue);
    await server.shutdown();
  });

  test('replayed messages are rejected', () async {
    final server = await startServer(approve: () => true);
    final c = await pairedLiveClient(server, await Identity.generate());
    Uint8List? captured;
    c.ch.debugOnSend = (bytes) => captured ??= Uint8List.fromList(bytes);
    await c.ch.sendJson({'t': Msg.move, 'x': 0.25, 'y': 0.25});
    await Future.delayed(const Duration(milliseconds: 200));
    final before = fake.inputs.length;
    c.ws.add(captured!); // replay the exact same ciphertext
    final closed = await c.closedWithin(const Duration(seconds: 3));
    final ok = before == 1 && fake.inputs.length == 1 && closed;
    record('replay', 'Replayed message rejected', 'Re-sending captured traffic', ok);
    expect(ok, isTrue);
    await server.shutdown();
  });

  test('unpaired devices cannot inject input', () async {
    final server = await startServer(approve: () => false);
    final c = await dial(server.boundPort, await Identity.generate());
    c.ch.sendJson({'t': Msg.move, 'x': 0.9, 'y': 0.9});
    c.ch.sendJson({'t': Msg.text, 's': 'rm -rf /'});
    final denied = await c.until(Msg.denied);
    await Future.delayed(const Duration(milliseconds: 200));
    final ok = denied != null && fake.inputs.isEmpty;
    record('unpaired', 'No input before approval', 'Unknown device trying to type/click', ok);
    expect(ok, isTrue);
    await server.shutdown();
  });

  test('oversized messages are rejected', () async {
    final server = await startServer(approve: () => true);
    final c = await pairedLiveClient(server, await Identity.generate());
    c.ch.sendJson({'t': Msg.text, 's': 'A' * (200 * 1024)});
    final closed = await c.closedWithin(const Duration(seconds: 3));
    final ok = closed && fake.inputs.isEmpty;
    record('oversize', 'Oversized message rejected', 'Memory exhaustion / DoS', ok);
    expect(ok, isTrue);
    await server.shutdown();
  });

  test('fuzzed input never reaches the OS and the host survives', () async {
    final server = await startServer(approve: () => true);
    final c = await pairedLiveClient(server, await Identity.generate());
    final rng = Random(42);
    final junk = <Object?>[null, true, -1, 1e300, -1e300, 'x' * 5000, [], {}, 'DROP TABLE', -999999999999];
    var sent = 0;
    for (var i = 0; i < 400; i++) {
      final types = [Msg.move, Msg.button, Msg.wheel, Msg.key, Msg.text, Msg.touch, Msg.nav, 'evil', 'td'];
      c.ch.sendJson({
        't': types[rng.nextInt(types.length)],
        'x': junk[rng.nextInt(junk.length)] is double ? 0.5 : junk[rng.nextInt(junk.length)],
        'y': junk[rng.nextInt(junk.length)],
        'b': junk[rng.nextInt(junk.length)],
        'k': ['../../etc', 'a' * 40, '\u0000', 'enter;calc'][rng.nextInt(4)],
        'm': ['root', 'sudo', 'win'],
        's': rng.nextBool() ? '\u0000\u0007' : 'x' * 3000,
        'p': List.filled(2000, 0.5),
      });
      sent++;
    }
    c.ch.sendJson({'t': Msg.move, 'x': 0.1, 'y': 0.2}); // one valid message
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 10) &&
        !(fake.inputs.isNotEmpty && fake.inputs.last['x'] == 0.1 && fake.inputs.last['y'] == 0.2)) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    bench['fuzz_400_msgs_ms'] = sw.elapsedMilliseconds;
    // Survived: the session is still live and the valid message sent after
    // all the junk was applied.
    final last = fake.inputs.isEmpty ? null : fake.inputs.last;
    final alive = server.viewer != null && last?['x'] == 0.1 && last?['y'] == 0.2;
    final valid = fake.inputs.every((m) => sanitizeInput(m, 'windows') != null);
    final ok = valid && fake.inputs.isNotEmpty && alive;
    record('fuzz', 'Fuzzed input contained ($sent messages)', 'Malformed input reaching SendInput', ok,
        '${fake.inputs.length} sanitized messages applied');
    expect(ok, isTrue);
    await server.shutdown();
  });

  test('pairing floods are rate-limited', () async {
    final server = await startServer(
      limiter: RateLimiter(connectionsPerMinute: 1000, pairingsPer10Min: 4),
      approve: () => false,
    );
    var limited = 0;
    for (var i = 0; i < 7; i++) {
      final c = await dial(server.boundPort, await Identity.generate());
      final d = await c.until(Msg.denied);
      if ((d?['reason'] as String? ?? '').startsWith('Too many')) limited++;
    }
    final ok = limited == 3;
    record('flood', 'Pairing-prompt flood rate-limited', 'Spamming "wants to connect" popups', ok,
        '$limited of 7 attempts blocked');
    expect(ok, isTrue);
    await server.shutdown();
  });

  test('repeated bad handshakes lock the address out', () async {
    final server = await startServer(limiter: RateLimiter(connectionsPerMinute: 1000, failuresBeforeLockout: 5));
    for (var i = 0; i < 5; i++) {
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/ws');
      ws.add(jsonEncode({'t': 'hello', 'v': 2, 'spk': 'AAAA', 'epk': 'AAAA'}));
      await ws.toList().timeout(const Duration(seconds: 3), onTimeout: () => []);
    }
    var refused = false;
    try {
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/ws');
      await ws.close();
    } catch (_) {
      refused = true;
    }
    record('lockout', 'Brute-force lockout', 'Repeated malformed handshakes', refused);
    expect(refused, isTrue);
    await server.shutdown();
  });

  test('only local-network addresses are accepted', () async {
    bool local(String a) => isLocalNetwork(InternetAddress(a));
    final ok = local('192.168.1.15') &&
        local('10.0.0.7') &&
        local('172.20.1.1') &&
        local('127.0.0.1') &&
        local('fe80::1') &&
        local('fd12::1') &&
        local('::ffff:192.168.0.2') &&
        !local('8.8.8.8') &&
        !local('172.32.0.1') &&
        !local('2001:4860::8888') &&
        !local('::ffff:1.1.1.1');
    record('lan', 'Internet addresses refused', 'Connections from outside the LAN', ok);
    expect(ok, isTrue);
  });

  test('every session gets fresh keys (forward secrecy)', () async {
    final server = await startServer(approve: () => true);
    final id = await Identity.generate();
    final a = await pairedLiveClient(server, id);
    final sas1 = a.hs.sas;
    Uint8List? ct1, ct2;
    a.ch.debugOnSend = (b) => ct1 ??= Uint8List.fromList(b);
    await a.ch.sendJson({'t': Msg.ack});
    await a.ch.close();
    await Future.delayed(const Duration(milliseconds: 200));
    final b = await pairedLiveClient(server, id);
    b.ch.debugOnSend = (x) => ct2 ??= Uint8List.fromList(x);
    await b.ch.sendJson({'t': Msg.ack});
    // Same identities, same plaintext: different ciphertext and session code.
    final ok = !constantTimeBytesEqual(ct1!, ct2!) && sas1 != b.hs.sas;
    record('pfs', 'Fresh ephemeral keys per session', 'Recorded traffic decrypted after a key leak', ok);
    expect(ok, isTrue);
    await b.ch.close();
    await server.shutdown();
  });

  // ---- Benchmarks --------------------------------------------------------

  test('benchmark: handshake latency', () async {
    final server = await startServer(approve: () => true);
    final id = await Identity.generate();
    (await pairedLiveClient(server, id)).ch.close();
    final times = <double>[];
    for (var i = 0; i < 20; i++) {
      final sw = Stopwatch()..start();
      final c = await dial(server.boundPort, id);
      times.add(sw.elapsedMicroseconds / 1000);
      await c.ch.close();
    }
    times.sort();
    bench['handshake_ms_median'] = times[times.length ~/ 2];
    bench['handshake_ms_p95'] = times[(times.length * 0.95).floor() - 1];
    await server.shutdown();
  });

  test('benchmark: ChaCha20-Poly1305 throughput', () async {
    final aead = Chacha20.poly1305Aead();
    final key = await aead.newSecretKey();
    final frame = Uint8List.fromList(List.generate(100 * 1024, (i) => i & 0xFF));
    final nonce = List<int>.filled(12, 0);
    for (var i = 0; i < 5; i++) {
      await aead.encrypt(frame, secretKey: key, nonce: nonce); // warm-up
    }
    const n = 60;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      final box = await aead.encrypt(frame, secretKey: key, nonce: nonce);
      await aead.decrypt(box, secretKey: key);
    }
    final perFrameMs = sw.elapsedMicroseconds / 1000 / n;
    bench['aead_frame_kb'] = 100;
    bench['aead_ms_per_frame_roundtrip'] = perFrameMs;
    bench['aead_mb_per_s'] = (100 / 1024) / (perFrameMs / 1000);
  });

  test('benchmark: encrypted stream over loopback', () async {
    store.quality = QualityPreset.sharp;
    final server = await startServer(approve: () => true);
    final c = await pairedLiveClient(server, await Identity.generate());
    var frames = 0;
    var bytes = 0;
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 3)) {
      final m = await c.ch.receive();
      if (m is Uint8List) {
        frames++;
        bytes += m.length;
        c.ch.sendJson({'t': Msg.ack});
      }
    }
    final secs = sw.elapsedMicroseconds / 1e6;
    bench['stream_fps'] = frames / secs;
    bench['stream_mb_per_s'] = bytes / 1048576 / secs;
    bench['stream_target_fps'] = QualityPreset.sharp.fps;
    await c.ch.close();
    await server.shutdown();
  });
}
