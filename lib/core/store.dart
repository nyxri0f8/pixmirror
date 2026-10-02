import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/vault.dart';
import 'protocol.dart';
import 'secure_channel.dart';

/// A device we have paired with, pinned by its public identity key. Pairing
/// is mutual, so one pairing works in both directions.
class TrustedDevice {
  TrustedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.publicKey,
  });

  /// Fingerprint of [publicKey].
  final String id;
  String name;
  final String platform;
  final String publicKey; // base64 X25519

  Map<String, Object> toJson() =>
      {'id': id, 'name': name, 'platform': platform, 'pk': publicKey};

  static TrustedDevice? fromJson(Map<String, dynamic> j) {
    final pk = j['pk'];
    // Entries from protocol v1 (shared secrets) are dropped: re-pair once.
    if (pk is! String) return null;
    return TrustedDevice(
      id: j['id'] as String,
      name: j['name'] as String,
      platform: j['platform'] as String,
      publicKey: pk,
    );
  }
}

/// Persistent identity, trust list and preferences.
class Store extends ChangeNotifier {
  Store._(this._prefs, this.identity);

  final SharedPreferences _prefs;

  /// Long-term X25519 identity. The device id is its fingerprint.
  final Identity identity;
  String get deviceId => identity.fingerprint;
  late String deviceName;
  final Map<String, TrustedDevice> _trusted = {};

  /// Loads the identity private key, sealed by the OS key store (Windows
  /// DPAPI / Android Keystore), creating it on first run.
  static Future<Identity> _loadIdentity(SharedPreferences prefs) async {
    final sealed = prefs.getString('identitySealed');
    if (sealed != null) {
      try {
        return await Identity.fromSeed(await Vault.open(base64.decode(sealed)));
      } catch (_) {
        // Unreadable (e.g. profile copied to another machine): start fresh.
      }
    }
    final plain = prefs.getString('identityFallback');
    if (plain != null) return Identity.fromSeed(base64.decode(plain));

    final id = await Identity.generate();
    final seed = Uint8List.fromList(await id.seed());
    try {
      await prefs.setString('identitySealed', base64.encode(await Vault.seal(seed)));
    } catch (_) {
      // No OS vault (unit tests, unusual platforms): keep it in app storage.
      await prefs.setString('identityFallback', base64.encode(seed));
    }
    return id;
  }

  static Future<Store> load({required String defaultName}) async {
    final prefs = await SharedPreferences.getInstance();
    final store = Store._(prefs, await _loadIdentity(prefs));
    store._init(defaultName);
    return store;
  }

  static String get platform => Platform.isAndroid ? 'android' : 'windows';

  void _init(String defaultName) {
    _prefs.remove('deviceId'); // v1 random id, superseded by the key fingerprint
    deviceName = _prefs.getString('deviceName') ?? defaultName;
    final raw = _prefs.getString('trusted');
    if (raw != null) {
      final entries = jsonDecode(raw) as List;
      for (final j in entries) {
        final d = TrustedDevice.fromJson(j as Map<String, dynamic>);
        if (d != null) _trusted[d.id] = d;
      }
      // Purge v1 entries so their shared secrets don't linger on disk.
      if (_trusted.length != entries.length) _saveTrust();
    }
  }

  // ---- Trust -------------------------------------------------------------

  Iterable<TrustedDevice> get trusted => _trusted.values;
  TrustedDevice? trustedById(String id) => _trusted[id];
  bool isTrusted(String id) => _trusted.containsKey(id);

  void trust(TrustedDevice d) {
    _trusted[d.id] = d;
    _saveTrust();
  }

  void forget(String id) {
    _trusted.remove(id);
    _saveTrust();
  }

  void _saveTrust() {
    _prefs.setString(
        'trusted', jsonEncode(_trusted.values.map((d) => d.toJson()).toList()));
    notifyListeners();
  }

  // ---- Preferences ------------------------------------------------------

  set name(String value) {
    deviceName = value.trim().isEmpty ? deviceName : value.trim();
    _prefs.setString('deviceName', deviceName);
    notifyListeners();
  }

  QualityPreset get quality =>
      QualityPreset.values[(_prefs.getInt('quality') ?? 1)
          .clamp(0, QualityPreset.values.length - 1)];
  set quality(QualityPreset v) {
    _prefs.setInt('quality', v.index);
    notifyListeners();
  }

  ThemeMode get themeMode => ThemeMode.values[_prefs.getInt('themeMode') ?? 0];
  set themeMode(ThemeMode v) {
    _prefs.setInt('themeMode', v.index);
    notifyListeners();
  }

  /// Mirrors Apple's "Reduce Transparency": swaps glass for solid surfaces.
  bool get reduceTransparency => _prefs.getBool('reduceTransparency') ?? false;
  set reduceTransparency(bool v) {
    _prefs.setBool('reduceTransparency', v);
    notifyListeners();
  }

  double get pointerSpeed => _prefs.getDouble('pointerSpeed') ?? 1.4;
  set pointerSpeed(double v) {
    _prefs.setDouble('pointerSpeed', v);
    notifyListeners();
  }

  /// Phone viewer: true = laptop-style trackpad, false = tap where you touch.
  bool get trackpadMode => _prefs.getBool('trackpadMode') ?? true;
  set trackpadMode(bool v) {
    _prefs.setBool('trackpadMode', v);
    notifyListeners();
  }

  /// Windows only: accept connections from paired devices in the background.
  bool get allowControl => _prefs.getBool('allowControl') ?? true;
  set allowControl(bool v) {
    _prefs.setBool('allowControl', v);
    notifyListeners();
  }

  /// Phone: whether the first-run setup guide has been completed.
  bool get onboarded => _prefs.getBool('onboarded') ?? false;
  set onboarded(bool v) {
    _prefs.setBool('onboarded', v);
    notifyListeners();
  }

  bool get notifyNearby => _prefs.getBool('notifyNearby') ?? true;
  set notifyNearby(bool v) {
    _prefs.setBool('notifyNearby', v);
    notifyListeners();
  }
}
