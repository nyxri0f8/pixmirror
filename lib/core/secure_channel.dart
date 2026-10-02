import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// PixMirror secure transport (protocol v2).
///
/// Every device owns a long-term X25519 identity key. Its device id is the
/// key's fingerprint, so an id cannot be claimed without the private key.
///
/// Handshake (cleartext, public keys only):
///   viewer -> {t:hello, v:2, spk, epk, name, platform}
///   host   -> {t:hello, v:2, spk, epk, name, platform}
///
/// Both sides then compute, Noise-style:
///   ee = DH(e_viewer, e_host)    forward secrecy
///   se = DH(s_viewer, e_host)    proves the viewer owns its identity key
///   es = DH(e_viewer, s_host)    proves the host owns its identity key
///   okm = HKDF-SHA256(ee || se || es, salt = SHA-256(both hellos))
/// giving one ChaCha20-Poly1305 key per direction plus a 6-digit
/// short authentication string (SAS) shown during pairing. A man in the
/// middle necessarily produces different SAS values on the two screens.
///
/// After the handshake every WebSocket message is a binary AEAD box:
///   ciphertext || 16-byte Poly1305 tag
/// with a 96-bit nonce = 4 zero bytes || 64-bit per-direction counter, so a
/// replayed, reordered, dropped or modified message fails to decrypt and the
/// connection is closed.
const int kSecureVersion = 2;
const int _typeJson = 0x10;
const int _typeFrame = 0x11;

final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();
final _sha256 = Sha256();

class SecurityException implements Exception {
  SecurityException(this.message);
  final String message;
  @override
  String toString() => 'SecurityException: $message';
}

/// Long-term device identity.
class Identity {
  Identity._(this.keyPair, this.publicKey, this.fingerprint);

  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  /// Short, stable device id derived from the public key.
  final String fingerprint;

  /// Test-only: an identity that *claims* [publicKey] but holds [keyPair]'s
  /// private key — i.e. an impersonation attempt.
  @visibleForTesting
  static Future<Identity> forged(SimpleKeyPair keyPair, Uint8List publicKey) async =>
      Identity._(keyPair, publicKey, await fingerprintOf(publicKey));

  static Future<Identity> fromSeed(List<int> seed) async {
    final kp = await _x25519.newKeyPairFromSeed(seed);
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return Identity._(kp, pub, await fingerprintOf(pub));
  }

  static Future<Identity> generate() async {
    final kp = await _x25519.newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    return fromSeed(seed);
  }

  Future<List<int>> seed() => keyPair.extractPrivateKeyBytes();
}

Future<String> fingerprintOf(List<int> publicKey) async {
  final h = await _sha256.hash([...utf8.encode('pixmirror-id'), ...publicKey]);
  return base64Url.encode(h.bytes.sublist(0, 15)); // 20 chars, 120 bits
}

/// Result of a completed handshake.
class HandshakeResult {
  HandshakeResult(this.channel, this.peerPublicKey, this.peerId, this.peerName, this.peerPlatform, this.sas);

  final SecureChannel channel;
  final Uint8List peerPublicKey;
  final String peerId;
  final String peerName;
  final String peerPlatform;

  /// Six digits, identical on both screens unless someone is in the middle.
  final String sas;
}

Uint8List _b64(Object? v) {
  if (v is! String || v.length > 64) throw SecurityException('bad key encoding');
  final bytes = base64.decode(v);
  if (bytes.length != 32) throw SecurityException('bad key length');
  return bytes;
}

Map<String, dynamic> _parseHello(Object? data) {
  if (data is! String || data.length > 2048) throw SecurityException('bad hello');
  final Object? m;
  try {
    m = jsonDecode(data);
  } catch (_) {
    throw SecurityException('bad hello');
  }
  if (m is! Map<String, dynamic> || m['t'] != 'hello') throw SecurityException('bad hello');
  if (m['v'] != kSecureVersion) {
    throw SecurityException('unsupported protocol version ${m['v']}');
  }
  return m;
}

String _clean(Object? v, String fallback, [int max = 64]) {
  if (v is! String) return fallback;
  final s = v.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
  if (s.isEmpty) return fallback;
  return s.length > max ? s.substring(0, max) : s;
}

/// Runs the handshake on [ws]. [incoming] must be the socket's single
/// subscription (as a StreamIterator) so no message is lost.
Future<HandshakeResult> handshake({
  required WebSocket ws,
  required StreamIterator<dynamic> incoming,
  required Identity identity,
  required bool initiator,
  required String name,
  required String platform,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final ephemeral = await _x25519.newKeyPair();
  final epk = (await ephemeral.extractPublicKey()).bytes;
  final myHello = jsonEncode({
    't': 'hello',
    'v': kSecureVersion,
    'spk': base64.encode(identity.publicKey),
    'epk': base64.encode(epk),
    'name': name,
    'platform': platform,
  });

  Future<String> receiveHello() async {
    if (!await incoming.moveNext().timeout(timeout)) throw SecurityException('closed during handshake');
    final data = incoming.current;
    if (data is! String) throw SecurityException('bad hello');
    return data;
  }

  late final String viewerHello, hostHello;
  if (initiator) {
    ws.add(myHello);
    viewerHello = myHello;
    hostHello = await receiveHello();
  } else {
    viewerHello = await receiveHello();
    _parseHello(viewerHello);
    ws.add(myHello);
    hostHello = myHello;
  }
  final peer = _parseHello(initiator ? hostHello : viewerHello);
  final peerStatic = _b64(peer['spk']);
  final peerEphemeral = _b64(peer['epk']);
  if (_eq(peerStatic, identity.publicKey)) throw SecurityException('reflected identity');

  Future<List<int>> dh(SimpleKeyPair mine, List<int> theirs) async =>
      (await _x25519.sharedSecretKey(
        keyPair: mine,
        remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
      ))
          .extractBytes();

  final ee = await dh(ephemeral, peerEphemeral);
  // se: viewer static x host ephemeral; es: viewer ephemeral x host static.
  final se = initiator ? await dh(identity.keyPair, peerEphemeral) : await dh(ephemeral, peerStatic);
  final es = initiator ? await dh(ephemeral, peerStatic) : await dh(identity.keyPair, peerEphemeral);
  for (final s in [ee, se, es]) {
    if (s.every((b) => b == 0)) throw SecurityException('low-order point');
  }

  final transcript = await _sha256.hash([...utf8.encode(viewerHello), 0, ...utf8.encode(hostHello)]);
  final okm = await (await Hkdf(hmac: Hmac.sha256(), outputLength: 72).deriveKey(
    secretKey: SecretKey([...ee, ...se, ...es]),
    nonce: transcript.bytes,
    info: utf8.encode('pixmirror v2 session'),
  ))
      .extractBytes();
  final viewerToHost = SecretKey(okm.sublist(0, 32));
  final hostToViewer = SecretKey(okm.sublist(32, 64));
  final sasNum = ByteData.sublistView(Uint8List.fromList(okm.sublist(64, 72))).getUint64(0) % 1000000;

  final channel = SecureChannel._(
    ws,
    incoming,
    initiator ? viewerToHost : hostToViewer,
    initiator ? hostToViewer : viewerToHost,
  );

  // Key confirmation: each side proves it derived the same keys before any
  // application data flows. A wrong key fails the AEAD tag here.
  channel.sendJson({'t': 'finished'});
  final fin = await channel.receive().timeout(timeout);
  if (fin is! Map || fin['t'] != 'finished') throw SecurityException('key confirmation failed');

  return HandshakeResult(
    channel,
    peerStatic,
    await fingerprintOf(peerStatic),
    _clean(peer['name'], 'Unknown device'),
    peer['platform'] == 'android' ? 'android' : (peer['platform'] == 'windows' ? 'windows' : 'unknown'),
    sasNum.toString().padLeft(6, '0'),
  );
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

bool constantTimeBytesEqual(List<int> a, List<int> b) => _eq(a, b);

/// Encrypted, ordered, replay-proof message channel over a WebSocket.
class SecureChannel {
  SecureChannel._(this._ws, this._incoming, this._sendKey, this._recvKey);

  final WebSocket _ws;
  final StreamIterator<dynamic> _incoming;
  final SecretKey _sendKey;
  final SecretKey _recvKey;
  int _sendCounter = 0;

  /// Test-only tap on raw ciphertexts as they leave (for replay tests).
  @visibleForTesting
  void Function(Uint8List ciphertext)? debugOnSend;
  int _recvCounter = 0;

  /// Largest message this side accepts (set by the role: hosts expect small
  /// input messages, viewers expect frames).
  int maxMessageBytes = 16 * 1024 * 1024;

  // Encryption is async; chain sends so ciphertexts leave in counter order.
  Future<void> _sendChain = Future.value();

  static List<int> _nonce(int counter) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(4, counter);
    return n;
  }

  Future<void> _send(int type, List<int> payload) {
    final counter = _sendCounter++;
    final plain = Uint8List(payload.length + 1)
      ..[0] = type
      ..setRange(1, payload.length + 1, payload);
    _sendChain = _sendChain.then((_) async {
      final box = await _aead.encrypt(plain, secretKey: _sendKey, nonce: _nonce(counter));
      final out = Uint8List(box.cipherText.length + 16)
        ..setRange(0, box.cipherText.length, box.cipherText)
        ..setRange(box.cipherText.length, box.cipherText.length + 16, box.mac.bytes);
      debugOnSend?.call(out);
      try {
        _ws.add(out);
      } catch (_) {}
    });
    return _sendChain;
  }

  Future<void> sendJson(Map<String, Object?> m) => _send(_typeJson, utf8.encode(jsonEncode(m)));
  Future<void> sendFrame(Uint8List data) => _send(_typeFrame, data);

  /// Next message: a JSON map, or a Uint8List frame. Throws
  /// [SecurityException] on any tampering, replay or malformed input, and
  /// [StateError] when the socket closes.
  Future<Object> receive() async {
    if (!await _incoming.moveNext()) throw StateError('closed');
    return open(_incoming.current);
  }

  Future<Object> open(Object? data) async {
    if (data is! List<int>) throw SecurityException('unencrypted message');
    if (data.length < 17 || data.length > maxMessageBytes + 17) throw SecurityException('bad message size');
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final ct = Uint8List.sublistView(bytes, 0, bytes.length - 16);
    final mac = Mac(Uint8List.sublistView(bytes, bytes.length - 16));
    final List<int> plain;
    try {
      plain = await _aead.decrypt(SecretBox(ct, nonce: _nonce(_recvCounter), mac: mac), secretKey: _recvKey);
    } on SecretBoxAuthenticationError {
      throw SecurityException('authentication failed (tampered, replayed or wrong key)');
    }
    _recvCounter++;
    final type = plain[0];
    final payload = Uint8List.fromList(plain.sublist(1));
    if (type == _typeFrame) return payload;
    if (type != _typeJson) throw SecurityException('unknown message type');
    final Object? m;
    try {
      m = jsonDecode(utf8.decode(payload));
    } catch (_) {
      throw SecurityException('malformed message');
    }
    if (m is! Map<String, dynamic>) throw SecurityException('malformed message');
    return m;
  }

  /// Decrypted messages until the socket closes or a security error occurs.
  Stream<Object> messages() async* {
    while (true) {
      try {
        yield await receive();
      } on StateError {
        return;
      }
    }
  }

  Future<void> close() async {
    try {
      await _ws.close();
    } catch (_) {}
  }
}

/// True for loopback, link-local and private (RFC 1918 / ULA) addresses.
/// PixMirror only ever talks to devices on the local network.
bool isLocalNetwork(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal) return true;
  final r = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return r[0] == 10 ||
        (r[0] == 172 && r[1] >= 16 && r[1] <= 31) ||
        (r[0] == 192 && r[1] == 168) ||
        (r[0] == 100 && r[1] >= 64 && r[1] <= 127); // CGNAT / some hotspots
  }
  if (a.type == InternetAddressType.IPv6) {
    if ((r[0] & 0xFE) == 0xFC) return true; // fc00::/7 unique local
    // IPv4-mapped (::ffff:a.b.c.d)
    final mapped = r.sublist(0, 10).every((b) => b == 0) && r[10] == 0xFF && r[11] == 0xFF;
    if (mapped) return isLocalNetwork(InternetAddress.fromRawAddress(Uint8List.fromList(r.sublist(12))));
  }
  return false;
}
