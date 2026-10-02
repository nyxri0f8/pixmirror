import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/protocol.dart';
import 'screen_host.dart';

// Native functions exported by windows/runner/pixmirror_native.cpp.
typedef _CaptureC = Int32 Function(Int32, Int32, Int32, Int32,
    Pointer<Pointer<Uint8>>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>);
typedef _CaptureDart = int Function(int, int, int, int, Pointer<Pointer<Uint8>>,
    Pointer<Int32>, Pointer<Int32>, Pointer<Int32>);

class _Native {
  _Native() : _lib = DynamicLibrary.executable();
  final DynamicLibrary _lib;

  late final monitorCount =
      _lib.lookupFunction<Int32 Function(), int Function()>('pm_monitor_count');
  late final monitorRect = _lib.lookupFunction<
      Int32 Function(Int32, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>),
      int Function(int, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>,
          Pointer<Int32>)>('pm_monitor_rect');
  late final capture = _lib.lookupFunction<_CaptureC, _CaptureDart>('pm_capture_jpeg');
  late final invalidate =
      _lib.lookupFunction<Void Function(), void Function()>('pm_capture_invalidate');
  late final free =
      _lib.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('pm_free');
  late final cursor = _lib.lookupFunction<
      Int32 Function(Int32, Pointer<Double>, Pointer<Double>),
      int Function(int, Pointer<Double>, Pointer<Double>)>('pm_cursor');
  late final mouseAbs = _lib.lookupFunction<Void Function(Int32, Double, Double),
      void Function(int, double, double)>('pm_mouse_abs');
  late final mouseButton = _lib.lookupFunction<Void Function(Int32, Int32),
      void Function(int, int)>('pm_mouse_button');
  late final mouseWheel = _lib.lookupFunction<Void Function(Int32, Int32),
      void Function(int, int)>('pm_mouse_wheel');
  late final key =
      _lib.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('pm_key');
  late final type = _lib.lookupFunction<Void Function(Pointer<Uint16>, Int32),
      void Function(Pointer<Uint16>, int)>('pm_type');
}

/// Capture runs in its own isolate so GDI + JPEG work never janks the UI.
class _CaptureWorker {
  late final SendPort _requests;
  final _replies = ReceivePort();
  final _pending = <Completer<Object?>>[];
  late final Future<void> ready;

  _CaptureWorker() {
    final readyCompleter = Completer<void>();
    ready = readyCompleter.future;
    _replies.listen((msg) {
      if (msg is SendPort) {
        _requests = msg;
        readyCompleter.complete();
      } else if (_pending.isNotEmpty) {
        _pending.removeAt(0).complete(msg);
      }
    });
    Isolate.spawn(_main, _replies.sendPort);
  }

  Future<Frame?> capture(int monitor, QualityPreset q, bool skipUnchanged) async {
    await ready;
    final c = Completer<Object?>();
    _pending.add(c);
    _requests.send([monitor, q.maxWidth, q.quality, skipUnchanged ? 1 : 0]);
    final r = await c.future;
    if (r is! List) return null;
    final bytes = (r[0] as TransferableTypedData).materialize().asUint8List();
    return Frame(r[1] as int, r[2] as int, bytes);
  }

  static void _main(SendPort replies) {
    final native = _Native();
    final port = ReceivePort();
    replies.send(port.sendPort);
    final out = calloc<Pointer<Uint8>>();
    final len = calloc<Int32>();
    final w = calloc<Int32>();
    final h = calloc<Int32>();
    port.listen((msg) {
      final a = msg as List;
      final rc = native.capture(a[0] as int, a[1] as int, a[2] as int, a[3] as int,
          out, len, w, h);
      if (rc != 1) {
        replies.send(rc);
        return;
      }
      final bytes = Uint8List.fromList(out.value.asTypedList(len.value));
      native.free(out.value);
      replies.send([TransferableTypedData.fromList([bytes]), w.value, h.value]);
    });
  }
}

const _vk = <String, int>{
  'backspace': 0x08, 'tab': 0x09, 'enter': 0x0D, 'shift': 0x10, 'ctrl': 0x11,
  'alt': 0x12, 'pause': 0x13, 'capslock': 0x14, 'escape': 0x1B, 'space': 0x20,
  'pageup': 0x21, 'pagedown': 0x22, 'end': 0x23, 'home': 0x24, 'left': 0x25,
  'up': 0x26, 'right': 0x27, 'down': 0x28, 'printscreen': 0x2C, 'insert': 0x2D,
  'delete': 0x2E, 'win': 0x5B, 'menu': 0x5D,
  'f1': 0x70, 'f2': 0x71, 'f3': 0x72, 'f4': 0x73, 'f5': 0x74, 'f6': 0x75,
  'f7': 0x76, 'f8': 0x77, 'f9': 0x78, 'f10': 0x79, 'f11': 0x7A, 'f12': 0x7B,
  'volumemute': 0xAD, 'volumedown': 0xAE, 'volumeup': 0xAF,
  'mediaplay': 0xB3, 'medianext': 0xB0, 'mediaprev': 0xB1,
  ';': 0xBA, '=': 0xBB, ',': 0xBC, '-': 0xBD, '.': 0xBE, '/': 0xBF, '`': 0xC0,
  '[': 0xDB, r'\': 0xDC, ']': 0xDD, "'": 0xDE,
};

int? _vkFor(String name) {
  final n = name.toLowerCase();
  final named = _vk[n];
  if (named != null) return named;
  if (n.length == 1) {
    final c = n.toUpperCase().codeUnitAt(0);
    if ((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)) return c;
  }
  return null;
}

class WindowsHost extends ScreenHost {
  final _native = _Native();
  final _worker = _CaptureWorker();
  final _stopped = StreamController<void>.broadcast();
  final _cx = calloc<Double>();
  final _cy = calloc<Double>();
  QualityPreset _quality = QualityPreset.balanced;
  bool _running = false;

  @override
  String get platform => 'windows';
  @override
  bool get running => _running;
  @override
  Stream<void> get stopped => _stopped.stream;

  @override
  Future<bool> start(QualityPreset quality) async {
    _quality = quality;
    _running = true;
    return true;
  }

  @override
  Future<void> stop() async => _running = false;

  @override
  void configure(QualityPreset quality) {
    _quality = quality;
    _native.invalidate();
  }

  @override
  int get monitorCount => _native.monitorCount();

  @override
  (int, int) get screenSize {
    final l = calloc<Int32>(), t = calloc<Int32>(), w = calloc<Int32>(), h = calloc<Int32>();
    try {
      _native.monitorRect(monitor, l, t, w, h);
      return (w.value, h.value);
    } finally {
      calloc
        ..free(l)
        ..free(t)
        ..free(w)
        ..free(h);
    }
  }

  @override
  Future<Frame?> nextFrame({bool force = false}) {
    if (force) _native.invalidate();
    return _worker.capture(monitor, _quality, true);
  }

  @override
  CursorState? cursor() {
    final kind = _native.cursor(monitor, _cx, _cy);
    if (kind == 0) return const CursorState(0, 0, CursorKind.hidden);
    return CursorState(_cx.value, _cy.value, CursorKind.values[kind.clamp(0, 4)]);
  }

  @override
  Future<bool> inputAvailable() async => true;

  void _withModifiers(List mods, void Function() action) {
    final vks = [for (final m in mods) _vkFor(m as String)].whereType<int>().toList();
    for (final vk in vks) {
      _native.key(vk, 1);
    }
    action();
    for (final vk in vks.reversed) {
      _native.key(vk, 0);
    }
  }

  @override
  void handleInput(Map<String, dynamic> msg) {
    switch (msg['t']) {
      case Msg.move:
        _native.mouseAbs(monitor, (msg['x'] as num).toDouble(), (msg['y'] as num).toDouble());
      case Msg.button:
        _native.mouseButton(msg['b'] as int, msg['d'] == true ? 1 : 0);
      case Msg.wheel:
        _native.mouseWheel((msg['dx'] as num).round(), (msg['dy'] as num).round());
      case Msg.text:
        final s = msg['s'] as String;
        if (s.isEmpty) return;
        final units = s.codeUnits;
        final buf = calloc<Uint16>(units.length);
        buf.asTypedList(units.length).setAll(0, units);
        _native.type(buf, units.length);
        calloc.free(buf);
      case Msg.key:
        final vk = _vkFor(msg['k'] as String);
        final mods = (msg['m'] as List?) ?? const [];
        if (vk == null) {
          if (mods.isNotEmpty) {
            // Bare modifier tap, e.g. the Windows key.
            _withModifiers(mods, () {});
          }
          return;
        }
        _withModifiers(mods, () {
          _native.key(vk, 1);
          _native.key(vk, 0);
        });
    }
  }
}
