import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Proves knowledge of the pairing secret without sending it.
String signNonce(String secret, String nonce) =>
    Hmac(sha256, base64Url.decode(secret)).convert(utf8.encode(nonce)).toString();

bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Six-digit code shown on both screens during pairing (like Bluetooth).
String pairingCode() => Random.secure().nextInt(1000000).toString().padLeft(6, '0');
