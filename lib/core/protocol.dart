import 'dart:convert';
import 'dart:typed_data';

/// Wire protocol shared by hosts (the device being mirrored) and viewers.
///
/// Transport: one WebSocket per session on [kHostPort], secured by the
/// handshake in secure_channel.dart. After it, every message is encrypted:
///   * JSON control + input messages (`{"t": <type>, ...}`)
///   * video frames: [kFrameTag][u16 w][u16 h][jpeg]
///
/// Session flow (all encrypted): host -> pairing{code} (unknown key, user
/// compares the code) -> paired{} -> waiting{} (phone asked to share) ->
/// welcome{...}; or denied{reason}. Then frames/cursor out, input/acks in.
const int kProtocolVersion = 2;
const int kDiscoveryPort = 47800;
const int kHostPort = 47801;
const int kFrameTag = 0x01;

abstract final class Msg {
  static const hello = 'hello';
  static const challenge = 'challenge';
  static const auth = 'auth';
  static const pairing = 'pairing';
  static const paired = 'paired';
  static const welcome = 'welcome';
  static const waiting = 'waiting'; // host is asking its user to start sharing
  static const denied = 'denied';
  static const ack = 'ack';
  static const config = 'cfg';
  static const cursor = 'cur';
  static const screen = 'screen';
  static const bye = 'bye';

  // Input: desktop hosts.
  static const move = 'move'; // {x,y} normalized absolute
  static const button = 'btn'; // {b:0|1|2, d:bool}
  static const wheel = 'wheel'; // {dx,dy} in 120ths of a notch
  // Input: touch hosts.
  static const touch = 'touch'; // {p:[x,y,...], ms} one-shot gesture
  static const touchDown = 'td'; // {x,y} live finger
  static const touchMove = 'tm';
  static const touchUp = 'tu';
  static const nav = 'nav'; // {a:'back'|'home'|'recents'|...}
  // Input: both.
  static const text = 'text'; // {s}
  static const key = 'key'; // {k, m:[mods]}
}

String encodeMsg(String type, [Map<String, Object?> fields = const {}]) =>
    jsonEncode({'t': type, ...fields});

Map<String, dynamic>? decodeMsg(Object? data) {
  if (data is! String) return null;
  try {
    final v = jsonDecode(data);
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}

Uint8List encodeFrame(Uint8List jpeg, int width, int height) {
  final out = Uint8List(5 + jpeg.length);
  final view = ByteData.sublistView(out);
  out[0] = kFrameTag;
  view.setUint16(1, width);
  view.setUint16(3, height);
  out.setRange(5, out.length, jpeg);
  return out;
}

class Frame {
  const Frame(this.width, this.height, this.jpeg);
  final int width;
  final int height;
  final Uint8List jpeg;
}

Frame? decodeFrame(Object? data) {
  if (data is! List<int> || data.length < 6) return null;
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  if (bytes[0] != kFrameTag) return null;
  final view = ByteData.sublistView(bytes);
  return Frame(
    view.getUint16(1),
    view.getUint16(3),
    Uint8List.sublistView(bytes, 5),
  );
}

/// Stream quality presets shown in settings.
enum QualityPreset {
  saver('Data saver', 960, 55, 20),
  balanced('Balanced', 1280, 70, 30),
  sharp('Sharp', 1920, 82, 30);

  const QualityPreset(this.label, this.maxWidth, this.quality, this.fps);
  final String label;
  final int maxWidth;
  final int quality;
  final int fps;
}
