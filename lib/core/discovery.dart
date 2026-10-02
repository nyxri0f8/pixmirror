import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';
import 'secure_channel.dart';

/// Device ids are 120-bit key fingerprints in base64url (20 chars).
final _idFormat = RegExp(r'^[A-Za-z0-9_-]{20}$');

class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.platform,
    required this.address,
    required this.port,
    required this.sharing,
    required this.lastSeen,
  });

  final String id;
  String name;
  final String platform;
  InternetAddress address;
  int port;

  /// Whether the peer currently accepts viewers.
  bool sharing;
  DateTime lastSeen;

  bool get isPhone => platform == 'android';
}

/// LAN discovery using UDP broadcast beacons.
///
/// Every device broadcasts a small JSON beacon every 1.5 s and listens for
/// others. Broadcast (rather than mDNS) needs no extra platform services and
/// works the same on Windows and Android.
class Discovery {
  Discovery({
    required this.id,
    required this.name,
    required this.platform,
    required this.isSharing,
    this.port = kDiscoveryPort,
  });

  final String id;
  String Function() name;
  final String platform;
  final bool Function() isSharing;

  /// UDP port for beacons (configurable so tests don't collide with a
  /// running app).
  final int port;

  final Map<String, Peer> _peers = {};
  final _changes = StreamController<List<Peer>>.broadcast();
  RawDatagramSocket? _socket;
  Timer? _beacon;
  Timer? _sweep;

  Stream<List<Peer>> get changes => _changes.stream;
  List<Peer> get peers => _peers.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Future<void> start() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
    } catch (_) {
      // Port taken (e.g. a second instance): still announce from any port.
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _socket!
      ..broadcastEnabled = true
      ..listen(_onEvent);
    _beacon = Timer.periodic(const Duration(milliseconds: 1500), (_) => announce());
    _sweep = Timer.periodic(const Duration(seconds: 2), (_) => _expire());
    announce();
  }

  List<int> _payload() => utf8.encode(jsonEncode({
        'pm': kProtocolVersion,
        'id': id,
        'name': name(),
        'platform': platform,
        'port': kHostPort,
        'share': isSharing(),
      }));

  final Map<String, DateTime> _repliedAt = {};

  /// Sends a beacon now (also called when sharing state changes).
  Future<void> announce() async {
    final socket = _socket;
    if (socket == null) return;
    final payload = _payload();
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback || addr.isLinkLocal) continue;
          // Directed broadcast for the common /24 home network. Windows only
          // sends 255.255.255.255 out of one adapter, so this matters there.
          final parts = addr.address.split('.');
          targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
        }
      }
    } catch (_) {}
    for (final t in targets) {
      try {
        socket.send(payload, t, port);
      } catch (_) {}
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    try {
      // Beacons are untrusted input: bound their size, accept only LAN
      // senders, and validate every field before it reaches the UI.
      if (dg.data.length > 1024 || !isLocalNetwork(dg.address)) return;
      final j = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (j['pm'] != kProtocolVersion) return;
      final peerId = j['id'];
      final port = j['port'];
      if (peerId is! String || !_idFormat.hasMatch(peerId)) return;
      if (port is! int || port < 1024 || port > 65535) return;
      if (j['platform'] != 'android' && j['platform'] != 'windows') return;
      final rawName = j['name'];
      if (rawName is! String) return;
      j['name'] = rawName.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
      if ((j['name'] as String).isEmpty || (j['name'] as String).length > 64) return;
      if (peerId == id) return;
      // Answer directly. Some phones and routers drop outgoing broadcasts;
      // a unicast reply means hearing either side is enough for both to
      // discover each other.
      final now0 = DateTime.now();
      final last = _repliedAt[peerId];
      if (last == null || now0.difference(last) > const Duration(milliseconds: 1200)) {
        _repliedAt[peerId] = now0;
        try {
          _socket?.send(_payload(), dg.address, port);
        } catch (_) {}
      }
      final existing = _peers[peerId];
      final now = DateTime.now();
      if (existing == null) {
        _peers[peerId] = Peer(
          id: peerId,
          name: j['name'] as String,
          platform: j['platform'] as String,
          address: dg.address,
          port: j['port'] as int,
          sharing: j['share'] == true,
          lastSeen: now,
        );
        _changes.add(peers);
      } else {
        final changed = existing.name != j['name'] ||
            existing.sharing != (j['share'] == true) ||
            existing.address != dg.address;
        existing
          ..name = j['name'] as String
          ..sharing = j['share'] == true
          ..address = dg.address
          ..port = j['port'] as int
          ..lastSeen = now;
        if (changed) _changes.add(peers);
      }
    } catch (_) {}
  }

  void _expire() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 6));
    final before = _peers.length;
    _peers.removeWhere((_, p) => p.lastSeen.isBefore(cutoff));
    if (_peers.length != before) _changes.add(peers);
  }

  void dispose() {
    _beacon?.cancel();
    _sweep?.cancel();
    _socket?.close();
    _changes.close();
  }
}
