import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';

/// A device we have paired with. Pairing is mutual: the same secret
/// authenticates either side, so pairing once works in both directions.
class TrustedDevice {
  TrustedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.secret,
  });

  final String id;
  String name;
  final String platform;
  final String secret; // base64

  Map<String, Object> toJson() =>
      {'id': id, 'name': name, 'platform': platform, 'secret': secret};

  static TrustedDevice fromJson(Map<String, dynamic> j) => TrustedDevice(
        id: j['id'] as String,
        name: j['name'] as String,
        platform: j['platform'] as String,
        secret: j['secret'] as String,
      );
}

/// Persistent identity, trust list and preferences.
class Store extends ChangeNotifier {
  Store._(this._prefs);

  final SharedPreferences _prefs;
  late String deviceId;
  late String deviceName;
  final Map<String, TrustedDevice> _trusted = {};

  static Future<Store> load({required String defaultName}) async {
    final store = Store._(await SharedPreferences.getInstance());
    store._init(defaultName);
    return store;
  }

  static String get platform => Platform.isAndroid ? 'android' : 'windows';

  static String randomToken(int bytes) {
    final rng = Random.secure();
    return base64Url.encode(List.generate(bytes, (_) => rng.nextInt(256)));
  }

  void _init(String defaultName) {
    deviceId = _prefs.getString('deviceId') ?? randomToken(12);
    _prefs.setString('deviceId', deviceId);
    deviceName = _prefs.getString('deviceName') ?? defaultName;
    final raw = _prefs.getString('trusted');
    if (raw != null) {
      for (final j in jsonDecode(raw) as List) {
        final d = TrustedDevice.fromJson(j as Map<String, dynamic>);
        _trusted[d.id] = d;
      }
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
