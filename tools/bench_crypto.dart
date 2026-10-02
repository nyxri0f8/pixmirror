// AOT benchmark of the frame cipher, matching release builds:
//   dart compile exe tools/bench_crypto.dart -o build/bench_crypto.exe
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

Future<void> main() async {
  final aead = Chacha20.poly1305Aead();
  final key = await aead.newSecretKey();
  final frame = Uint8List.fromList(List.generate(100 * 1024, (i) => i & 0xFF));
  final nonce = List<int>.filled(12, 0);
  for (var i = 0; i < 20; i++) {
    await aead.encrypt(frame, secretKey: key, nonce: nonce);
  }
  const n = 300;
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    final box = await aead.encrypt(frame, secretKey: key, nonce: nonce);
    await aead.decrypt(box, secretKey: key);
  }
  final ms = sw.elapsedMicroseconds / 1000 / n;

  final x = X25519();
  final a = await x.newKeyPair();
  final b = await (await x.newKeyPair()).extractPublicKey();
  final sw2 = Stopwatch()..start();
  for (var i = 0; i < 200; i++) {
    await x.sharedSecretKey(keyPair: a, remotePublicKey: b);
  }
  final dhMs = sw2.elapsedMicroseconds / 1000 / 200;

  final out = {
    'aot_aead_ms_per_frame_roundtrip': ms,
    'aot_aead_mb_per_s': (100 / 1024) / (ms / 1000),
    'aot_x25519_ms': dhMs,
  };
  stdout.writeln(jsonEncode(out));
  File('build/security/aot.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(out));
}
