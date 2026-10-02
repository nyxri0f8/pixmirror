// PixMirror security test suite — 20 tests + transport benchmarks.
//
//   flutter test test/security_test.dart
//
// Runtime tests attack the real HostServer / Discovery / RemoteSession code
// over loopback sockets. Tests 15 and 17 are static audits of the Android
// manifest and the source tree (marked "static"); tests 14 and 20 add live
// checks against a running pixmirror.exe when one is present; test 19
// queries the public OSV vulnerability database.
//
// Results: build/security/report.json → tools/make_security_chart.py →
// docs/security-benchmark.png.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixmirror/core/discovery.dart';
import 'package:pixmirror/core/host_server.dart';
import 'package:pixmirror/core/input_guard.dart';
import 'package:pixmirror/core/protocol.dart';
import 'package:pixmirror/core/remote_session.dart';
import 'package:pixmirror/core/secure_channel.dart';
import 'package:pixmirror/core/store.dart';
import 'package:pixmirror/platform/screen_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Screen host stand-in: serves a 100 KB "frame" and records every input
/// that would reach SendInput / the accessibility service.
class FakeHost extends ScreenHost {
  FakeHost({this.platformName = 'windows', this.isRunning = true});
  final String platformName;
  bool isRunning;
  final inputs = <Map<String, dynamic>>[];
  final _frame = Uint8List.fromList(List.generate(100 * 1024, (i) => (i * 31) & 0xFF));

  @override
  String get platform => platformName;
  @override
  bool get running => isRunning;
  @override
  Stream<void> get stopped => const Stream.empty();
  @override
  Future<bool> start(QualityPreset quality) async => isRunning = true;
  @override
  Future<void> stop() async => isRunning = false;
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

void record(int n, String title, String kind, String threat, bool passed, [String detail = '']) => results.add(
    {'n': n, 'title': title, 'kind': kind, 'threat': threat, 'passed': passed, 'detail': detail});

late Store store;
late FakeHost fake;

RateLimiter generous() => RateLimiter(connectionsPerMinute: 100000, pairingsPer10Min: 100000, failuresBeforeLockout: 100000);

Future<HostServer> startServer({RateLimiter? limiter, bool Function()? approve, FakeHost? host, bool Function(InternetAddress)? allow}) async {
  final server = HostServer(
    store: store,
    host: host ?? fake,
    accepting: () => true,
    port: 0,
    bindAddress: InternetAddress.loopbackIPv4,
    allowAddress: allow ?? isLocalNetwork,
    limiter: limiter ?? generous(),
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

  /// Counts frames for [d] (acking each); stops early if the socket closes.
  Future<int> frames(Duration d) async {
    var n = 0;
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      try {
        final m = await ch.receive().timeout(end.difference(DateTime.now()));
        if (m is Uint8List) {
          n++;
          ch.sendJson({'t': Msg.ack});
        }
      } catch (_) {
        break;
      }
    }
    return n;
  }

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

Future<Client> live(HostServer server, Identity id) async {
  final c = await dial(server.boundPort, id);
  expect(await c.until(Msg.welcome), isNotNull, reason: 'session should go live');
  return c;
}

/// Raw socket that sends a v2 hello with fresh keys and returns the socket
/// after reading the host's hello — for crafting broken follow-ups.
Future<(WebSocket, StreamIterator<dynamic>)> rawAfterHello(int port) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
  final it = StreamIterator<dynamic>(ws);
  final s = await X25519().newKeyPair();
  final e = await X25519().newKeyPair();
  ws.add(jsonEncode({
    't': 'hello',
    'v': 2,
    'spk': base64.encode((await s.extractPublicKey()).bytes),
    'epk': base64.encode((await e.extractPublicKey()).bytes),
    'name': 'raw',
    'platform': 'android',
  }));
  await it.moveNext().timeout(const Duration(seconds: 5));
  return (ws, it);
}

Future<bool> socketClosed(StreamIterator<dynamic> it, [Duration d = const Duration(seconds: 3)]) async {
  try {
    while (await it.moveNext().timeout(d)) {}
    return true;
  } catch (_) {
    return false;
  }
}

Future<int?> runningAppPid() async {
  if (!Platform.isWindows) return null;
  final r = await Process.run('tasklist', ['/FI', 'IMAGENAME eq pixmirror.exe', '/FO', 'CSV', '/NH']);
  final m = RegExp(r'"pixmirror\.exe","(\d+)"').firstMatch(r.stdout as String);
  return m == null ? null : int.parse(m.group(1)!);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    store = await Store.load(defaultName: 'TestHost');
  });
  setUp(() => fake = FakeHost());

  tearDownAll(() async {
    results.sort((a, b) => (a['n'] as int).compareTo(b['n'] as int));
    final dir = Directory('build/security')..createSync(recursive: true);
    File('${dir.path}/report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'generated': DateTime.now().toIso8601String(),
      'dart': Platform.version.split(' ').first,
      'os': Platform.operatingSystemVersion,
      'tests': results,
      'benchmarks': bench,
    }));
  });

  // ---- 1 -------------------------------------------------------------------
  test('01 pairing brute-force resistance', () async {
    // a) The code is not a password: it is re-derived from every handshake,
    //    so there is nothing stable to guess, and no code-entry endpoint.
    final server = await startServer(approve: () => false);
    final a = await Identity.generate();
    final codes = <String>[];
    for (var i = 0; i < 8; i++) {
      final c = await dial(server.boundPort, a);
      codes.add(c.hs.sas);
      c.ch.sendJson({'t': 'pair_code', 'code': codes.last}); // "guess" — no such handler
      await c.until(Msg.denied);
    }
    var fresh = true;
    for (var i = 1; i < codes.length; i++) {
      if (codes[i] == codes[i - 1]) fresh = false;
    }
    final notTrusted = !store.isTrusted(await fingerprintOf(a.publicKey));
    await server.shutdown();
    // b) Prompt flood: 4 pairing attempts per address per 10 min.
    final limited = await startServer(limiter: RateLimiter(connectionsPerMinute: 1000, pairingsPer10Min: 4), approve: () => false);
    var blocked = 0;
    for (var i = 0; i < 7; i++) {
      final c = await dial(limited.boundPort, await Identity.generate());
      final d = await c.until(Msg.denied);
      if ((d?['reason'] as String? ?? '').startsWith('Too many')) blocked++;
    }
    await limited.shutdown();
    final ok = fresh && notTrusted && blocked == 3;
    record(1, 'Pairing brute-force resistance', 'runtime', 'Guessing or spamming the 6-digit pairing code', ok,
        'code changes every handshake; no code-entry endpoint; $blocked/7 extra attempts rate-limited');
    expect(ok, isTrue);
  });

  // ---- 2 -------------------------------------------------------------------
  test('02 man-in-the-middle', () async {
    String? hostCode;
    final server = await startServer();
    server.addListener(() => hostCode ??= server.pendingPair?.code);
    final attacker = await Identity.generate();
    final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    relay.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      unawaited(handshake(ws: ws, incoming: StreamIterator<dynamic>(ws), identity: attacker, initiator: false, name: 'TestHost', platform: 'windows')
          .then((_) {}, onError: (_) {}));
    });
    final victim = await dial(relay.port, await Identity.generate());
    await dial(server.boundPort, attacker);
    await Future.delayed(const Duration(milliseconds: 300));
    final ok = hostCode != null && hostCode != victim.hs.sas && victim.hs.peerId != store.deviceId;
    record(2, 'Man-in-the-middle (MITM)', 'runtime', 'Attacker relaying between phone and PC', ok,
        'codes differ (${victim.hs.sas} vs $hostCode) and the relay\'s identity does not match the PC');
    expect(ok, isTrue);
    server.answerPair(false);
    await relay.close(force: true);
    await server.shutdown();
  });

  // ---- 3 -------------------------------------------------------------------
  test('03 replay attack', () async {
    final server = await startServer(approve: () => true);
    final c = await live(server, await Identity.generate());
    Uint8List? captured;
    c.ch.debugOnSend = (b) => captured ??= Uint8List.fromList(b);
    await c.ch.sendJson({'t': Msg.move, 'x': 0.25, 'y': 0.25});
    await Future.delayed(const Duration(milliseconds: 200));
    final before = fake.inputs.length;
    c.ws.add(captured!);
    final closed = await c.closedWithin(const Duration(seconds: 3));
    final ok = before == 1 && fake.inputs.length == 1 && closed;
    record(3, 'Replay attack', 'runtime', 'Re-sending captured traffic', ok, 'replayed ciphertext rejected, session closed');
    expect(ok, isTrue);
    await server.shutdown();
  });

  // ---- 4 -------------------------------------------------------------------
  test('04 packet tampering', () async {
    final server = await startServer(approve: () => true);
    var rejected = 0;
    for (final pos in [0, 8, -1]) {
      fake.inputs.clear();
      final c = await live(server, await Identity.generate());
      c.ch.debugOnSend = (b) => b[pos < 0 ? b.length + pos : pos] ^= 0x01;
      c.ch.sendJson({'t': Msg.move, 'x': 0.5, 'y': 0.5});
      if (await c.closedWithin(const Duration(seconds: 3)) && fake.inputs.isEmpty) rejected++;
      await Future.delayed(const Duration(milliseconds: 150));
    }
    final ok = rejected == 3;
    record(4, 'Packet tampering', 'runtime', 'Flipping bits in ciphertext or auth tag', ok, '$rejected/3 bit-flips (start, middle, tag) rejected');
    expect(ok, isTrue);
    await server.shutdown();
  });

  // ---- 5 -------------------------------------------------------------------
  test('05 malformed packet fuzzing', () async {
    final server = await startServer(approve: () => true);
    final rng = Random(5);
    var survived = 0;
    for (var i = 0; i < 40; i++) {
      final c = await live(server, await Identity.generate());
      final len = [0, 1, 16, 17, 64, 4096][i % 6] + rng.nextInt(8);
      c.ws.add(Uint8List.fromList(List.generate(len, (_) => rng.nextInt(256))));
      if (i.isOdd) c.ws.add('not json at all {{{');
      if (await c.closedWithin(const Duration(seconds: 2))) survived++;
      await Future.delayed(const Duration(milliseconds: 30));
    }
    final after = await live(server, await Identity.generate()); // host still serving
    final ok = survived == 40 && fake.inputs.isEmpty && after.hs.sas.length == 6;
    record(5, 'Malformed packet fuzzing', 'runtime', 'Random binary / text packets after the handshake', ok,
        '40 random packets: every session dropped cleanly, host kept serving');
    expect(ok, isTrue);
    await server.shutdown();
  });

  // ---- 6 -------------------------------------------------------------------
  test('06 oversized packet / memory exhaustion', () async {
    final server = await startServer(approve: () => true);
    final c = await live(server, await Identity.generate());
    c.ch.sendJson({'t': Msg.text, 's': 'A' * (200 * 1024)});
    final closed = await c.closedWithin(const Duration(seconds: 3));
    final (raw, it) = await rawAfterHello(server.boundPort); // oversized pre-auth too
    raw.add('x' * (3 * 1024 * 1024));
    final rawClosed = await socketClosed(it);
    final ok = closed && rawClosed && fake.inputs.isEmpty;
    record(6, 'Oversized packet / memory exhaustion', 'runtime', '200 KB input message, 3 MB pre-auth blob', ok,
        'hosts accept at most 64 KB per message; both dropped');
    expect(ok, isTrue);
    await server.shutdown();
  });

  // ---- 7 -------------------------------------------------------------------
  test('07 authentication bypass', () async {
    final server = await startServer(approve: () => true);
    // a) skip key confirmation and send plaintext input
    final (a, ia) = await rawAfterHello(server.boundPort);
    a.add(jsonEncode({'t': 'move', 'x': 0.9, 'y': 0.9}));
    final aClosed = await socketClosed(ia);
    // b) send a forged "finished" box with no valid key
    final (b, ib) = await rawAfterHello(server.boundPort);
    b.add(Uint8List.fromList(List.generate(48, (i) => i)));
    final bClosed = await socketClosed(ib);
    // c) jump straight to a "welcome"/input message without any hello
    final c = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/ws');
    final ic = StreamIterator<dynamic>(c);
    c.add(jsonEncode({'t': 'welcome'}));
    c.add(jsonEncode({'t': 'key', 'k': 'f4', 'm': ['alt']}));
    final cClosed = await socketClosed(ic);
    final ok = aClosed && bClosed && cClosed && fake.inputs.isEmpty && server.viewer == null;
    record(7, 'Authentication bypass', 'runtime', 'Skipping key confirmation / forging the handshake', ok,
        '3 bypass attempts: all closed, zero input reached the OS');
    expect(ok, isTrue);
    await server.shutdown();
  });

  // ---- 8 -------------------------------------------------------------------
  test('08 protocol downgrade', () async {
    final server = await startServer(approve: () => true);
    var refused = 0;
    for (final v in [1, 0, 3, '2', null]) {
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/ws');
      final it = StreamIterator<dynamic>(ws);
      ws.add(jsonEncode({'t': 'hello', 'v': v, 'id': 'x', 'name': 'old', 'platform': 'android'}));
      if (await socketClosed(it)) refused++;
    }
    final ok = refused == 5 && server.pendingPair == null && fake.inputs.isEmpty;
    record(8, 'Protocol downgrade', 'runtime', 'Forcing the old unencrypted v1 protocol', ok, '$refused/5 non-v2 hellos refused, no fallback');
    expect(ok, isTrue);
    await server.shutdown();
  });

  // ---- 9 -------------------------------------------------------------------
  test('09 key-pinning validation', () async {
    // a) Host side: same name, different key → treated as a stranger.
    final server = await startServer(approve: () => true);
    final real = await Identity.generate();
    (await live(server, real)).ch.close();
    await Future.delayed(const Duration(milliseconds: 150));
    var prompted = false;
    server.addListener(() => prompted = prompted || server.pendingPair != null);
    final imposter = await dial(server.boundPort, await Identity.generate()); // same "Tester" name
    await imposter.until(Msg.welcome);
    await server.shutdown();
    // b) Viewer side: the answering host's key doesn't match the pinned id.
    final fakeHostId = await Identity.generate();
    final evil = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    evil.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      unawaited(handshake(ws: ws, incoming: StreamIterator<dynamic>(ws), identity: fakeHostId, initiator: false, name: 'nyx', platform: 'windows')
          .then((_) {}, onError: (_) {}));
    });
    final pinnedId = await fingerprintOf((await Identity.generate()).publicKey);
    final session = RemoteSession(
      peer: Peer(id: pinnedId, name: 'nyx', platform: 'windows', address: InternetAddress.loopbackIPv4, port: evil.port, sharing: true, lastSeen: DateTime.now()),
      store: store,
    );
    await session.connect();
    await Future.delayed(const Duration(milliseconds: 300));
    final warned = session.phase == SessionPhase.closed && (session.error ?? '').startsWith('Security warning');
    await evil.close(force: true);
    final ok = prompted && warned;
    record(9, 'Key-pinning validation', 'runtime', 'A device impersonating a paired PC or phone', ok,
        'host re-prompts for an unknown key; viewer stops with a security warning on a key mismatch');
    expect(ok, isTrue);
  });

  // ---- 10 ------------------------------------------------------------------
  test('10 session isolation', () async {
    final server = await startServer(approve: () => true);
    final a = await live(server, await Identity.generate());
    // A second device cannot join or inject while A is live.
    final b = await dial(server.boundPort, await Identity.generate());
    b.ch.sendJson({'t': Msg.move, 'x': 0.7, 'y': 0.7});
    final bDenied = await b.until(Msg.denied);
    // A's captured ciphertext cannot be spliced into another session.
    final idA2 = await Identity.generate();
    Uint8List? fromA;
    a.ch.debugOnSend = (x) => fromA ??= Uint8List.fromList(x);
    await a.ch.sendJson({'t': Msg.move, 'x': 0.11, 'y': 0.11});
    await a.ch.close();
    await Future.delayed(const Duration(milliseconds: 200));
    final c = await live(server, idA2);
    final applied = fake.inputs.length;
    c.ws.add(fromA!);
    final cClosed = await c.closedWithin(const Duration(seconds: 3));
    final ok = bDenied != null && cClosed && fake.inputs.length == applied && fake.inputs.every((m) => m['x'] != 0.7);
    record(10, 'Session isolation', 'runtime', 'Second device hijacking or splicing into a session', ok,
        'one viewer at a time; ciphertext from one session is rejected by another');
    expect(ok, isTrue);
    await server.shutdown();
  });

  // ---- 11 ------------------------------------------------------------------
  test('11 disconnect / reconnect security', () async {
    final events = <String>[];
    final server = await startServer(approve: () => true);
    server.events.stream.listen(events.add);
    final id = await Identity.generate();
    final first = await live(server, id);
    await first.frames(const Duration(milliseconds: 600)); // laggy-ish session with frames in flight
    await first.ch.close();
    await Future.delayed(const Duration(milliseconds: 400));
    final released = server.viewer == null;
    events.clear();
    final second = await live(server, id); // trusted: no prompt, full handshake again
    final silent = events.any((e) => e.startsWith('trusted')) && !events.any((e) => e.startsWith('pairing'));
    final freshKeys = first.hs.sas != second.hs.sas;
    final ok = released && silent && freshKeys;
    record(11, 'Disconnect / reconnect security', 'runtime', 'Stale sessions or key reuse after a drop', ok,
        'session released on disconnect; reconnect re-authenticates with fresh keys');
    expect(ok, isTrue);
    await server.shutdown();
  });

  // ---- 12 ------------------------------------------------------------------
  test('12 forward secrecy', () async {
    final server = await startServer(approve: () => true);
    final id = await Identity.generate();
    final a = await live(server, id);
    Uint8List? ct1, ct2;
    a.ch.debugOnSend = (b) => ct1 ??= Uint8List.fromList(b);
    await a.ch.sendJson({'t': Msg.ack});
    await a.ch.close();
    await Future.delayed(const Duration(milliseconds: 200));
    final b = await live(server, id);
    b.ch.debugOnSend = (x) => ct2 ??= Uint8List.fromList(x);
    await b.ch.sendJson({'t': Msg.ack});
    final ok = !constantTimeBytesEqual(ct1!, ct2!) && a.hs.sas != b.hs.sas;
    record(12, 'Forward secrecy', 'runtime', 'Decrypting recorded traffic after a key leak', ok,
        'ephemeral X25519 per session: same identities, same plaintext, different ciphertext');
    expect(ok, isTrue);
    await server.shutdown();
  });

  // ---- 13 ------------------------------------------------------------------
  test('13 network discovery privacy', () async {
    const port = 47933;
    final listen = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    final seen = <Map<String, dynamic>>[];
    listen.listen((e) {
      final d = listen.receive();
      if (d == null) return;
      try {
        final j = jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>;
        if (j['id'] == store.deviceId) seen.add({...j, '_bytes': d.data.length});
      } catch (_) {}
    });
    final disc = Discovery(id: store.deviceId, name: () => 'TestHost', platform: 'windows', isSharing: () => true, port: port);
    await disc.start();
    await Future.delayed(const Duration(milliseconds: 600));
    // Windows hands a unicast datagram to only one socket on a shared port,
    // so stop listening before probing the discovery parser.
    listen.close();
    // Hostile beacons: only the well-formed one may become a peer.
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    void send(Object payload) => s.send(payload is String ? utf8.encode(payload) : payload as List<int>, InternetAddress.loopbackIPv4, port);
    final good = {'pm': kProtocolVersion, 'id': 'AAAAAAAAAAAAAAAAAAAA', 'name': 'Phone\u0007\u001b[31m', 'platform': 'android', 'port': kHostPort, 'share': true};
    send('{{not json');
    send(List.filled(4096, 65));
    send(jsonEncode({...good, 'id': '../../etc/passwd'}));
    send(jsonEncode({...good, 'id': 'BBBBBBBBBBBBBBBBBBBB', 'platform': 'ios'}));
    send(jsonEncode({...good, 'id': 'CCCCCCCCCCCCCCCCCCCC', 'port': 22}));
    send(jsonEncode({...good, 'id': 'DDDDDDDDDDDDDDDDDDDD', 'name': 'x' * 500}));
    send(jsonEncode({...good, 'pm': 1, 'id': 'EEEEEEEEEEEEEEEEEEEE'}));
    send(jsonEncode(good));
    await Future.delayed(const Duration(milliseconds: 500));
    final peers = disc.peers;
    disc.dispose();
    s.close();
    final beacon = seen.isEmpty ? <String, dynamic>{} : seen.first;
    final fields = beacon.keys.where((k) => k != '_bytes').toSet();
    final minimal = fields.difference({'pm', 'id', 'name', 'platform', 'port', 'share'}).isEmpty && fields.isNotEmpty;
    final noKeys = !jsonEncode(beacon).contains(base64.encode(store.identity.publicKey));
    final small = (beacon['_bytes'] as int? ?? 9999) < 256;
    final onlyGood = peers.length == 1 && peers.first.id == good['id'] && !peers.first.name.contains('\u001b');
    final ok = minimal && noKeys && small && onlyGood;
    record(13, 'Network discovery privacy', 'runtime', 'What the Wi-Fi beacon leaks; spoofed beacons', ok,
        'beacon = 6 fields, ${beacon['_bytes']} bytes, no keys; 7 hostile beacons dropped, control chars stripped');
    expect(ok, isTrue);
  });

  // ---- 14 ------------------------------------------------------------------
  test('14 port exposure', () async {
    final server = await startServer(approve: () => true);
    final client = HttpClient();
    Future<(int, String?)> req(String method, String path) async {
      final r = await client.open(method, '127.0.0.1', server.boundPort, path);
      final res = await r.close();
      await res.drain<void>();
      return (res.statusCode, res.headers.value('server'));
    }
    final codes = [await req('GET', '/'), await req('GET', '/ws'), await req('POST', '/ws'), await req('GET', '/../etc/passwd')];
    final http404 = codes.every((c) => c.$1 == 404) && codes.every((c) => c.$2 == null);
    await server.shutdown();
    // Non-LAN addresses get 403 before anything else happens.
    final wan = await startServer(allow: (_) => false);
    final r = await client.open('GET', '127.0.0.1', wan.boundPort, '/ws');
    final wanStatus = (await r.close()).statusCode;
    await wan.shutdown();
    client.close(force: true);
    // Live app: exactly one TCP and one UDP port, nothing else listening.
    var liveNote = 'no running pixmirror.exe — live check skipped';
    var liveOk = true;
    final pid = await runningAppPid();
    if (pid != null) {
      final ns = (await Process.run('netstat', ['-ano'])).stdout as String;
      final mine = ns.split('\n').where((l) => l.trim().endsWith(' $pid') && (l.contains('LISTENING') || l.trim().startsWith('UDP'))).toList();
      final ports = mine.map((l) => RegExp(r':(\d+)\s').firstMatch(l)?.group(1)).whereType<String>().toSet();
      liveOk = ports.length == 2 && ports.containsAll({'47800', '47801'});
      liveNote = 'live app (pid $pid) listens on ${ports.join(' + ')} only';
    }
    final ok = http404 && wanStatus == 403 && liveOk;
    record(14, 'Port exposure', pid == null ? 'runtime' : 'runtime + live', 'Extra services, HTTP probing, WAN access', ok,
        'only /ws upgrades (other paths 404, no Server header); WAN 403; $liveNote');
    expect(ok, isTrue);
  });

  // ---- 15 ------------------------------------------------------------------
  test('15 android accessibility authorization', () async {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final input = RegExp(r'<service\s+android:name="\.InputService"(.*?)>', dotAll: true).firstMatch(manifest)?.group(1) ?? '';
    final bound = input.contains('android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"') && input.contains('android:exported="false"');
    final services = RegExp(r'<service[^>]*?>', dotAll: true).allMatches(manifest).map((m) => m.group(0)!).toList();
    final noneExported = services.every((s) => s.contains('android:exported="false"'));
    final receivers = !manifest.contains('<receiver') && !manifest.contains('<provider');
    // Only MainActivity's method channel may drive the service.
    final kt = Directory('android/app/src/main/kotlin').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.kt'));
    final callers = kt.where((f) => f.readAsStringSync().contains('InputService.instance')).map((f) => f.uri.pathSegments.last).toSet();
    // Remote input only reaches the host after sanitizeInput, inside a live session.
    final hs = File('lib/core/host_server.dart').readAsStringSync();
    final gated = RegExp(r'host\.handleInput\(').allMatches(hs).length == 1 && hs.contains('final safe = sanitizeInput(m, host.platform);');
    final desktopInputDropped = sanitizeInput({'t': Msg.move, 'x': 0.5, 'y': 0.5}, 'android') == null &&
        sanitizeInput({'t': Msg.key, 'k': 'f4', 'm': ['alt']}, 'android') != null &&
        sanitizeInput({'t': Msg.nav, 'a': 'factoryReset'}, 'android') == null;
    final ok = bound && noneExported && receivers && callers.length == 1 && callers.contains('MainActivity.kt') && gated && desktopInputDropped;
    record(15, 'Android Accessibility authorization', 'static', 'Other apps driving the accessibility service', ok,
        'service bound by BIND_ACCESSIBILITY_SERVICE, not exported; only MainActivity drives it; input sanitised in live sessions');
    expect(ok, isTrue);
  });

  // ---- 16 ------------------------------------------------------------------
  test('16 windows SendInput authorization', () async {
    // Every state before "live" must apply zero input.
    final spy = FakeHost(isRunning: false); // forces the "ask to share" wait
    final server = await startServer(host: spy);
    var phase = '';
    server.addListener(() {
      if (server.pendingPair != null) server.answerPair(phase != 'decline');
      if (server.shareRequest != null && phase == 'share') server.answerShare(false);
    });
    phase = 'decline';
    final d = await dial(server.boundPort, await Identity.generate());
    d.ch.sendJson({'t': Msg.text, 's': 'whoami'});
    await d.until(Msg.denied);
    phase = 'share';
    final w = await dial(server.boundPort, await Identity.generate());
    w.ch.sendJson({'t': Msg.button, 'b': 0, 'd': true});
    await w.until(Msg.denied);
    final preLive = spy.inputs.length;
    // After going live, only sanitised input arrives.
    spy.isRunning = true;
    phase = 'live';
    final l = await live(server, await Identity.generate());
    l.ch.sendJson({'t': Msg.move, 'x': 7, 'y': -3}); // clamped
    l.ch.sendJson({'t': Msg.key, 'k': 'r', 'm': ['win', 'sudo']}); // bad modifier → dropped
    await Future.delayed(const Duration(milliseconds: 300));
    await l.ch.close();
    await Future.delayed(const Duration(milliseconds: 200));
    l.ch.sendJson({'t': Msg.move, 'x': 0.1, 'y': 0.1}); // after disconnect
    await Future.delayed(const Duration(milliseconds: 200));
    final ffi = File('lib/platform/windows_host.dart').readAsStringSync();
    final onlyHere = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.readAsStringSync().contains('pm_mouse_abs')).length == 1;
    final ok = preLive == 0 && spy.inputs.length == 1 && spy.inputs.first['x'] == 1.0 && onlyHere && ffi.contains("'pm_key'");
    record(16, 'Windows SendInput authorization', 'runtime', 'Injecting mouse/keys before or after approval', ok,
        '0 inputs while declined / waiting / disconnected; live input clamped & allow-listed; SendInput reachable from one place');
    expect(ok, isTrue);
    await server.shutdown();
  });

  // ---- 17 ------------------------------------------------------------------
  test('17 clipboard data leakage', () async {
    final apis = RegExp(r'Clipboard\.(getData|setData)|ClipboardManager|getPrimaryClip|GetClipboardData|SetClipboardData|OpenClipboard|SystemChannels\.platform.*Clipboard');
    final roots = ['lib', 'android/app/src/main/kotlin', 'windows/runner'];
    final hits = <String>[];
    for (final r in roots) {
      for (final f in Directory(r).listSync(recursive: true).whereType<File>()) {
        if (!RegExp(r'\.(dart|kt|cpp|h)$').hasMatch(f.path)) continue;
        if (apis.hasMatch(f.readAsStringSync())) hits.add(f.path);
      }
    }
    final proto = File('lib/core/protocol.dart').readAsStringSync().toLowerCase();
    final noClipMsg = !proto.contains('clip');
    final ok = hits.isEmpty && noClipMsg;
    record(17, 'Clipboard data leakage', 'static', 'Clipboard contents silently sent to the other device', ok,
        'no clipboard API in Dart, Kotlin or C++; no clipboard message in the protocol');
    expect(ok, isTrue);
  });

  // ---- 18 ------------------------------------------------------------------
  test('18 protocol parser fuzzing', () async {
    final rng = Random(18);
    // a) Handshake parser: 150 hostile hellos, then a real client must still get in.
    final server = await startServer(approve: () => true);
    final zero = base64.encode(List.filled(32, 0));
    final key = base64.encode(List.generate(32, (i) => i + 1));
    final hostile = <Object>[
      '', '{}', '[]', 'null', '{"t":"hello"}', '{"t":"hello","v":2}',
      jsonEncode({'t': 'hello', 'v': 2, 'spk': zero, 'epk': zero}),
      jsonEncode({'t': 'hello', 'v': 2, 'spk': 'not base64!!', 'epk': key}),
      jsonEncode({'t': 'hello', 'v': 2, 'spk': base64.encode(List.filled(31, 1)), 'epk': key}),
      jsonEncode({'t': 'hello', 'v': 2, 'spk': key, 'epk': key, 'name': 'x' * 5000}),
      jsonEncode({'t': 'hello', 'v': 2, 'spk': 12, 'epk': true}),
      Uint8List.fromList(List.generate(64, (i) => i)),
    ];
    var handled = 0;
    for (var i = 0; i < 150; i++) {
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.boundPort}/ws');
      final it = StreamIterator<dynamic>(ws);
      final h = i < hostile.length ? hostile[i] : utf8.decode(List.generate(rng.nextInt(300), (_) => 32 + rng.nextInt(90)));
      ws.add(h);
      if (await socketClosed(it)) handled++;
    }
    final stillServes = (await live(server, await Identity.generate())).hs.sas.length == 6;
    await server.shutdown();
    // b) Message / frame decoders: 20 000 random inputs, no throw.
    var threw = 0;
    for (var i = 0; i < 10000; i++) {
      final bytes = Uint8List.fromList(List.generate(rng.nextInt(40), (_) => rng.nextInt(256)));
      try {
        decodeFrame(bytes);
        decodeMsg(String.fromCharCodes(bytes));
      } catch (_) {
        threw++;
      }
    }
    // c) Input guard: 10 000 random messages; output is always itself valid.
    var guardBad = 0;
    final types = [Msg.move, Msg.button, Msg.wheel, Msg.key, Msg.text, Msg.touch, Msg.touchDown, Msg.nav, 'x'];
    final vals = <Object?>[null, -1, 0, 0.5, 1e300, -1e300, 'a', 'enter', '', true, [], {}, ['ctrl'], List.filled(600, 0.5)];
    for (var i = 0; i < 10000; i++) {
      final m = {
        't': types[rng.nextInt(types.length)],
        for (final k in ['x', 'y', 'b', 'd', 'dx', 'dy', 'k', 'm', 's', 'p', 'ms', 'a']) k: vals[rng.nextInt(vals.length)],
      };
      try {
        for (final plat in ['windows', 'android']) {
          final out = sanitizeInput(m, plat);
          if (out != null && sanitizeInput(out, plat) == null) guardBad++;
        }
      } catch (_) {
        guardBad++;
      }
    }
    final ok = handled == 150 && stillServes && threw == 0 && guardBad == 0;
    record(18, 'Protocol parser fuzzing', 'runtime', 'Crashing the handshake, decoders or input guard', ok,
        '150 hostile hellos + 10k decoder inputs + 10k input-guard messages: 0 crashes');
    expect(ok, isTrue);
  });

  // ---- 19 ------------------------------------------------------------------
  test('19 dependency & secret scanning', () async {
    // Secrets: every tracked file.
    final files = ((await Process.run('git', ['ls-files'])).stdout as String).split('\n').where((f) => f.trim().isNotEmpty).toList();
    final patterns = {
      'private key': RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
      'GitHub token': RegExp(r'gh[pousr]_[A-Za-z0-9]{36}'),
      'AWS key': RegExp(r'AKIA[0-9A-Z]{16}'),
      'Google API key': RegExp(r'AIza[0-9A-Za-z_\-]{35}'),
      'OpenAI/Anthropic key': RegExp(r'sk-(ant-)?[A-Za-z0-9_\-]{24,}'),
      'Slack token': RegExp(r'xox[baprs]-[A-Za-z0-9-]{10,}'),
      'hard-coded password': RegExp(r'''password\s*[:=]\s*['"][^'"]{6,}['"]''', caseSensitive: false),
    };
    final findings = <String>[];
    var scanned = 0;
    for (final f in files) {
      if (RegExp(r'\.(png|ico|jpg|woff2?|ttf|otf|jar|zip)$').hasMatch(f)) continue;
      if (RegExp(r'\.(jks|keystore|p12|pfx|pem)$|key\.properties$|\.env$').hasMatch(f)) findings.add('$f: credential file tracked');
      final file = File(f);
      if (!file.existsSync()) continue;
      String text;
      try {
        text = file.readAsStringSync();
      } catch (_) {
        continue;
      }
      scanned++;
      patterns.forEach((name, re) {
        if (re.hasMatch(text)) findings.add('$f: $name');
      });
    }
    // Dependencies: every hosted package in pubspec.lock against OSV.
    final lock = File('pubspec.lock').readAsStringSync();
    final pkgs = RegExp(r'\n  ([a-z0-9_]+):\n    dependency: [^\n]+\n    description:\n      name: [a-z0-9_]+\n      sha256: [0-9a-f]+\n      url: "https://pub\.dev"\n    source: hosted\n    version: "([^"]+)"')
        .allMatches(lock)
        .map((m) => (m.group(1)!, m.group(2)!))
        .toList();
    var vulns = -1;
    var osvNote = '';
    try {
      final http = HttpClient();
      final req = await http.postUrl(Uri.parse('https://api.osv.dev/v1/querybatch'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'queries': [for (final (n, v) in pkgs) {'package': {'name': n, 'ecosystem': 'Pub'}, 'version': v}]
      }));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      vulns = (body['results'] as List).where((r) => (r as Map)['vulns'] != null).length;
      osvNote = '${pkgs.length} packages checked against OSV: $vulns vulnerable';
      http.close();
    } catch (e) {
      osvNote = 'OSV query failed ($e)';
    }
    final ok = findings.isEmpty && vulns == 0;
    record(19, 'Dependency & secret scanning', 'runtime + OSV', 'Leaked keys in the repo; vulnerable packages', ok,
        '$scanned tracked files: ${findings.isEmpty ? 'no secrets' : findings.join('; ')}; $osvNote');
    bench['deps_checked'] = pkgs.length;
    expect(ok, isTrue);
  });

  // ---- 20 ------------------------------------------------------------------
  test('20 end-to-end security regression', () async {
    final steps = <String, bool>{};
    final events = <String>[];
    String? code;
    final server = await startServer();
    server.events.stream.listen(events.add);
    server.addListener(() {
      final p = server.pendingPair;
      if (p != null) {
        code = p.code;
        server.answerPair(true);
      }
    });
    final id = await Identity.generate();
    final a = await dial(server.boundPort, id);
    steps['pair: codes match'] = (await a.until(Msg.welcome)) != null && code == a.hs.sas;
    steps['encrypted frames flow'] = await a.frames(const Duration(milliseconds: 900)) >= 5;
    await a.ch.sendJson({'t': Msg.move, 'x': 0.3, 'y': 0.3});
    await Future.delayed(const Duration(milliseconds: 200));
    steps['input applied once'] = fake.inputs.length == 1;
    await a.ch.close();
    await Future.delayed(const Duration(milliseconds: 300));
    steps['session released'] = server.viewer == null;
    events.clear();
    final b = await live(server, id);
    steps['trusted reconnect is silent'] = events.any((e) => e.startsWith('trusted'));
    await b.ch.close();
    await Future.delayed(const Duration(milliseconds: 200));
    store.forget(await fingerprintOf(id.publicKey));
    events.clear();
    final c = await dial(server.boundPort, id);
    await c.until(Msg.welcome);
    steps['forgotten device must re-pair'] = events.any((e) => e.startsWith('pairing'));
    await c.ch.close();
    await server.shutdown();
    // Live exe, when running: v1 refused and a fresh v2 handshake matches.
    final pid = await runningAppPid();
    if (pid != null) {
      try {
        final old = await WebSocket.connect('ws://127.0.0.1:47801/ws');
        final it = StreamIterator<dynamic>(old);
        old.add(jsonEncode({'t': 'hello', 'v': 1, 'id': 'x', 'name': 'old', 'platform': 'android'}));
        steps['live app refuses v1'] = await socketClosed(it);
        final p = await dial(47801, await Identity.generate(), name: 'Security regression probe');
        final m = await p.ch.receive().timeout(const Duration(seconds: 5));
        steps['live app handshake + code'] = m is Map && (m['t'] == 'pairing' ? m['code'] == p.hs.sas : true);
        await p.ch.close();
      } catch (_) {
        steps['live app reachable'] = false;
      }
    }
    final failed = steps.entries.where((e) => !e.value).map((e) => e.key).toList();
    final ok = failed.isEmpty;
    record(20, 'End-to-end security regression', pid == null ? 'runtime' : 'runtime + live', 'The whole lifecycle, start to finish', ok,
        ok ? '${steps.length}/${steps.length} lifecycle steps pass${pid == null ? '' : ' (incl. the running app)'}' : 'failed: ${failed.join(', ')}');
    expect(ok, isTrue);
  });

  // ---- Benchmarks ----------------------------------------------------------
  test('benchmark: handshake latency', () async {
    final server = await startServer(approve: () => true);
    final id = await Identity.generate();
    (await live(server, id)).ch.close();
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
      await aead.encrypt(frame, secretKey: key, nonce: nonce);
    }
    const n = 60;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      final box = await aead.encrypt(frame, secretKey: key, nonce: nonce);
      await aead.decrypt(box, secretKey: key);
    }
    final perFrameMs = sw.elapsedMicroseconds / 1000 / n;
    bench['aead_ms_per_frame_roundtrip'] = perFrameMs;
    bench['aead_mb_per_s'] = (100 / 1024) / (perFrameMs / 1000);
  });

  test('benchmark: encrypted stream over loopback', () async {
    store.quality = QualityPreset.sharp;
    final server = await startServer(approve: () => true);
    final c = await live(server, await Identity.generate());
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
