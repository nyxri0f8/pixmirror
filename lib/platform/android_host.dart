import 'dart:async';

import 'package:flutter/services.dart';

import '../core/protocol.dart';
import 'screen_host.dart';

const native = MethodChannel('pixmirror/native');
const _frames = EventChannel('pixmirror/frames');

/// Shares the phone screen via MediaProjection and applies remote input via
/// the PixMirror accessibility service (see android/app/src/main/kotlin).
class AndroidHost extends ScreenHost {
  AndroidHost() {
    _frames.receiveBroadcastStream().listen((event) {
      final m = event as Map;
      if (m['stopped'] == true) {
        _running = false;
        _stopped.add(null);
        return;
      }
      final frame = Frame(m['w'] as int, m['h'] as int, m['jpeg'] as Uint8List);
      _size = (frame.width, frame.height);
      final waiter = _waiter;
      _waiter = null;
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(frame);
      } else {
        _latest = frame; // arrived after a timeout; hand it out next time
      }
    });
  }

  final _stopped = StreamController<void>.broadcast();
  Completer<Frame?>? _waiter;
  Frame? _latest;
  bool _running = false;
  (int, int) _size = (1080, 2400);

  @override
  String get platform => 'android';
  @override
  bool get running => _running;
  @override
  Stream<void> get stopped => _stopped.stream;

  @override
  (int, int) get screenSize => _size;

  static Map<String, int> _args(QualityPreset q) =>
      {'maxWidth': q.maxWidth, 'quality': q.quality, 'fps': q.fps};

  @override
  Future<bool> start(QualityPreset quality) async {
    final ok = await native.invokeMethod<bool>('startCapture', _args(quality)) ?? false;
    _running = ok;
    return ok;
  }

  @override
  Future<void> stop() async {
    await native.invokeMethod('stopCapture');
    _running = false;
  }

  @override
  void configure(QualityPreset quality) =>
      native.invokeMethod('captureSettings', _args(quality));

  @override
  Future<Frame?> nextFrame({bool force = false}) {
    final latest = _latest;
    if (latest != null) {
      _latest = null;
      return Future.value(latest);
    }
    final waiter = _waiter ?? Completer<Frame?>();
    _waiter = waiter;
    native.invokeMethod('requestFrame', {'force': force});
    // Android only emits when the screen changes; time out so the host loop
    // can notice disconnects.
    return waiter.future.timeout(const Duration(seconds: 1), onTimeout: () {
      if (identical(_waiter, waiter)) _waiter = null;
      return null;
    });
  }

  @override
  Future<Map<String, dynamic>> screenInfo() async {
    final m = await native.invokeMapMethod<String, dynamic>('screenInfo') ?? const {};
    if (m['w'] is int && m['h'] is int) _size = (m['w'] as int, m['h'] as int);
    return m;
  }

  @override
  Future<bool> inputAvailable() async =>
      await native.invokeMethod<bool>('inputEnabled') ?? false;

  @override
  void handleInput(Map<String, dynamic> msg) {
    switch (msg['t']) {
      case Msg.touch:
        native.invokeMethod('gesture', {
          'points': [for (final v in msg['p'] as List) (v as num).toDouble()],
          'duration': (msg['ms'] as num?)?.toInt() ?? 50,
        });
      case Msg.touchDown:
        native.invokeMethod('touchDown', _point(msg));
      case Msg.touchMove:
        native.invokeMethod('touchMove', _point(msg));
      case Msg.touchUp:
        native.invokeMethod('touchUp', _point(msg));
      case Msg.nav:
        native.invokeMethod('globalAction', {'action': msg['a']});
      case Msg.text:
        native.invokeMethod('typeText', {'text': msg['s']});
      case Msg.key:
        native.invokeMethod('key', {'key': msg['k']});
    }
  }

  static Map<String, double> _point(Map<String, dynamic> msg) =>
      {'x': (msg['x'] as num).toDouble(), 'y': (msg['y'] as num).toDouble()};
}
