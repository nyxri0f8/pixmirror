import 'protocol.dart';

/// Validates remote input before it reaches SendInput / the accessibility
/// service. Anything unexpected is dropped rather than "best-effort" applied:
/// wrong types, out-of-range coordinates, oversized text, unknown keys, or
/// input meant for the other platform.
Map<String, dynamic>? sanitizeInput(Map<String, dynamic> m, String hostPlatform) {
  final desktop = hostPlatform == 'windows';
  double? unit(Object? v) {
    if (v is! num || !v.isFinite) return null;
    return v.toDouble().clamp(0.0, 1.0);
  }

  switch (m['t']) {
    case Msg.move when desktop:
      final x = unit(m['x']), y = unit(m['y']);
      if (x == null || y == null) return null;
      return {'t': Msg.move, 'x': x, 'y': y};

    case Msg.button when desktop:
      final b = m['b'];
      if (b is! int || b < 0 || b > 2 || m['d'] is! bool) return null;
      return {'t': Msg.button, 'b': b, 'd': m['d']};

    case Msg.wheel when desktop:
      final dx = m['dx'], dy = m['dy'];
      if (dx is! num || dy is! num || !dx.isFinite || !dy.isFinite) return null;
      return {'t': Msg.wheel, 'dx': dx.clamp(-2400, 2400), 'dy': dy.clamp(-2400, 2400)};

    case Msg.touchDown || Msg.touchMove || Msg.touchUp when !desktop:
      final x = unit(m['x']), y = unit(m['y']);
      if (x == null || y == null) return null;
      return {'t': m['t'], 'x': x, 'y': y};

    case Msg.touch when !desktop:
      final p = m['p'];
      final ms = m['ms'];
      if (p is! List || p.length < 2 || p.length > 512 || p.length.isOdd) return null;
      if (ms is! num || !ms.isFinite) return null;
      final pts = <double>[];
      for (final v in p) {
        final u = unit(v);
        if (u == null) return null;
        pts.add(u);
      }
      return {'t': Msg.touch, 'p': pts, 'ms': ms.toInt().clamp(1, 10000)};

    case Msg.nav when !desktop:
      const allowed = {'back', 'home', 'recents', 'notifications', 'quickSettings', 'lock', 'screenshot'};
      final a = m['a'];
      return a is String && allowed.contains(a) ? {'t': Msg.nav, 'a': a} : null;

    case Msg.text:
      final s = m['s'];
      if (s is! String || s.isEmpty || s.length > 2000) return null;
      // Control characters other than newline/tab could smuggle keystrokes.
      final clean = s.replaceAll(RegExp(r'[\x00-\x08\x0B-\x1F\x7F]'), '');
      return clean.isEmpty ? null : {'t': Msg.text, 's': clean};

    case Msg.key:
      final k = m['k'];
      final mods = m['m'] ?? const [];
      if (k is! String || k.length > 16 || mods is! List || mods.length > 4) return null;
      if (!_keyName.hasMatch(k)) return null;
      const allowedMods = {'ctrl', 'alt', 'shift', 'win'};
      if (!mods.every((x) => x is String && allowedMods.contains(x))) return null;
      return {'t': Msg.key, 'k': k, 'm': mods.cast<String>().toSet().toList()};
  }
  return null;
}

/// Single printable characters or known key names; empty for bare modifiers.
final _keyName = RegExp(r"^([a-z0-9]{0,12}|[.,;=\-/\[\]\\'`])$");
