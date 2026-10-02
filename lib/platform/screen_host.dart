import 'dart:async';

import '../core/protocol.dart';

/// Pointer shape reported by desktop hosts so viewers can draw the cursor.
enum CursorKind { hidden, arrow, text, hand, other }

class CursorState {
  const CursorState(this.x, this.y, this.kind);
  final double x;
  final double y;
  final CursorKind kind;
}

/// What a device needs to provide to be mirrored and controlled.
abstract class ScreenHost {
  /// 'windows' or 'android'; tells viewers which input model to use.
  String get platform;

  bool get running;

  /// Emits when sharing stops from outside (e.g. Android "Stop sharing").
  Stream<void> get stopped;

  /// Starts capture. On Android this shows the system screen-capture consent.
  Future<bool> start(QualityPreset quality);
  Future<void> stop();

  void configure(QualityPreset quality);

  /// Returns the next frame, or null when the screen has not changed.
  Future<Frame?> nextFrame({bool force = false});

  int get monitorCount => 1;
  int monitor = 0;

  /// Physical size of the shared screen in pixels.
  (int, int) get screenSize;

  /// Device geometry for a true-to-life frame on the viewer (phones send
  /// corner radius and camera cutouts). Empty when not applicable.
  Future<Map<String, dynamic>> screenInfo() async => const {};

  /// Current cursor; null on hosts without a mouse pointer.
  CursorState? cursor() => null;

  /// Whether remote input can be applied right now.
  Future<bool> inputAvailable();

  void handleInput(Map<String, dynamic> msg);
}
