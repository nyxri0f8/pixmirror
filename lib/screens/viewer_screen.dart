import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_controller.dart';
import '../core/remote_session.dart';
import '../platform/screen_host.dart';
import '../ui/aurora.dart';
import '../ui/glass.dart';
import 'keys_sheet.dart';

/// Zoom/pan of the mirrored screen inside the viewport.
class _View {
  const _View(this.scale, this.offset);
  final double scale;
  final Offset offset;
}

class _Ptr {
  _Ptr(this.position, this.kind)
      : start = position,
        startTime = DateTime.now();
  Offset position;
  final Offset start;
  final DateTime startTime;
  final PointerDeviceKind kind;
  double travel = 0;
}

enum _Two { undecided, scroll, zoom }

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.app, required this.session});

  final AppController app;
  final RemoteSession session;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  RemoteSession get s => widget.session;
  bool get touchHost => s.isTouchHost;
  bool get phoneViewer => Platform.isAndroid;

  final _view = ValueNotifier(const _View(1, Offset.zero));
  final _localCursor = ValueNotifier<Offset?>(null);
  final _keyboardFocus = FocusNode();
  final _desktopFocus = FocusNode();
  final _typing = TextEditingController(text: _sentinel);
  static const _sentinel = '  ';

  Size _viewport = Size.zero;
  Rect _base = Rect.zero;
  final _pointers = <int, _Ptr>{};

  // Trackpad state.
  DateTime? _lastTapUp;
  bool _dragging = false;
  bool _touchModeDragging = false;
  Timer? _longPress;
  bool _longPressFired = false;

  // Two-finger state.
  _Two _two = _Two.undecided;
  double _twoStartDist = 0;
  double _twoStartScale = 1;
  Offset _twoLastCenter = Offset.zero;
  bool _twoMoved = false;
  DateTime? _twoStart;
  Offset _wheelRemainder = Offset.zero;

  // Touch host: a live remote finger.
  bool _fingerDown = false;
  DateTime _lastFingerMove = DateTime.now();

  // Move throttling.
  Offset? _pendingMove;
  Timer? _moveTimer;

  Size? _restoreWindowSize;

  @override
  void initState() {
    super.initState();
    s.addListener(_onSession);
    if (phoneViewer) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      _desktopFocus.requestFocus();
      if (touchHost) {
        _fitWindowToPhone();
        s.frame.addListener(_onFrameForWindow);
      }
    }
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    s.frame.removeListener(_onFrameForWindow);
    _moveTimer?.cancel();
    _longPress?.cancel();
    if (phoneViewer) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else if (_restoreWindowSize != null) {
      windowManager.setSize(_restoreWindowSize!, animate: true);
    }
    _view.dispose();
    _localCursor.dispose();
    _keyboardFocus.dispose();
    _desktopFocus.dispose();
    _typing.dispose();
    super.dispose();
  }

  double _fittedAspect = 0;

  /// Like iPhone Mirroring on the Mac: the window takes the phone's exact
  /// shape, and reshapes when the phone rotates.
  Future<void> _fitWindowToPhone() async {
    final aspect = _phoneAspect;
    if (aspect <= 0) return;
    _fittedAspect = aspect;
    try {
      _restoreWindowSize ??= await windowManager.getSize();
    } catch (_) {
      return;
    }
    final display = ui.PlatformDispatcher.instance.displays.first;
    final screenW = display.size.width / display.devicePixelRatio;
    final screenH = display.size.height / display.devicePixelRatio;
    // Title bar + toolbar + paddings + bezel.
    const chromeH = 44 + 78 + 24 + _bezel * 2;
    const chromeW = 48 + _bezel * 2;
    var h = math.min(screenH * 0.88 - chromeH, 900.0);
    var w = h * aspect;
    final maxW = screenW * 0.9 - chromeW;
    if (w > maxW) {
      w = maxW;
      h = w / aspect;
    }
    final width = math.max(w + chromeW, 380.0);
    try {
      await windowManager.setSize(Size(width, h + chromeH), animate: true);
    } catch (_) {
      // No native window (e.g. rendering previews); keep the current size.
    }
  }

  void _onFrameForWindow() {
    if ((_phoneAspect - _fittedAspect).abs() > 0.05) _fitWindowToPhone();
  }

  void _onSession() {
    if (s.phase == SessionPhase.closed && mounted) {
      final err = s.error;
      widget.app.endSession();
      Navigator.of(context).maybePop();
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      }
    } else {
      setState(() {});
    }
  }

  // ---- Geometry ------------------------------------------------------------

  Rect get _display {
    final v = _view.value;
    return Rect.fromLTWH(
      _base.left * v.scale + v.offset.dx,
      _base.top * v.scale + v.offset.dy,
      _base.width * v.scale,
      _base.height * v.scale,
    );
  }

  Offset _toRemote(Offset p) {
    final r = _display;
    return Offset(
      ((p.dx - r.left) / r.width).clamp(0.0, 1.0),
      ((p.dy - r.top) / r.height).clamp(0.0, 1.0),
    );
  }

  void _layout(Size viewport) {
    _viewport = viewport;
    final img = s.frame.value;
    final aspect = img != null
        ? img.width / img.height
        : (s.screenHeight == 0 ? 16 / 9 : s.screenWidth / s.screenHeight);
    var w = viewport.width;
    var h = w / aspect;
    if (h > viewport.height) {
      h = viewport.height;
      w = h * aspect;
    }
    _base = Rect.fromLTWH((viewport.width - w) / 2, (viewport.height - h) / 2, w, h);
  }

  _View _clamp(double scale, Offset off) {
    scale = scale.clamp(1.0, 5.0);
    double axis(double baseStart, double baseLen, double viewLen, double o) {
      final len = baseLen * scale;
      final start = baseStart * scale + o;
      if (len <= viewLen) return (viewLen - len) / 2 - baseStart * scale;
      if (start > 0) return -baseStart * scale;
      if (start + len < viewLen) return viewLen - len - baseStart * scale;
      return o;
    }

    return _View(
      scale,
      Offset(
        axis(_base.left, _base.width, _viewport.width, off.dx),
        axis(_base.top, _base.height, _viewport.height, off.dy),
      ),
    );
  }

  void _zoomAbout(Offset focal, double newScale) {
    final v = _view.value;
    final b = (focal - v.offset) / v.scale;
    _view.value = _clamp(newScale, focal - b * newScale.clamp(1.0, 5.0));
  }

  void _panBy(Offset d) {
    final v = _view.value;
    _view.value = _clamp(v.scale, v.offset + d);
  }

  /// Keeps the trackpad cursor on screen while zoomed in.
  void _followCursor(Offset n) {
    final v = _view.value;
    if (v.scale <= 1.01) return;
    final r = _display;
    final p = Offset(r.left + n.dx * r.width, r.top + n.dy * r.height);
    const margin = 48.0;
    var dx = 0.0, dy = 0.0;
    if (p.dx < margin) dx = margin - p.dx;
    if (p.dx > _viewport.width - margin) dx = _viewport.width - margin - p.dx;
    if (p.dy < margin) dy = margin - p.dy;
    if (p.dy > _viewport.height - margin) dy = _viewport.height - margin - p.dy;
    if (dx != 0 || dy != 0) _panBy(Offset(dx, dy));
  }

  // ---- Sending -------------------------------------------------------------

  void _queueMove(Offset n) {
    _pendingMove = n;
    _moveTimer ??= Timer(const Duration(milliseconds: 12), () {
      _moveTimer = null;
      final m = _pendingMove;
      _pendingMove = null;
      if (m != null) s.moveTo(m.dx, m.dy);
    });
  }

  void _flushMove() {
    _moveTimer?.cancel();
    _moveTimer = null;
    final m = _pendingMove;
    _pendingMove = null;
    if (m != null) s.moveTo(m.dx, m.dy);
  }

  Offset get _cursorNow {
    final local = _localCursor.value;
    if (local != null) return local;
    final c = s.cursor.value;
    return c == null ? const Offset(0.5, 0.5) : Offset(c.x, c.y);
  }

  void _sendWheel(Offset fingerDelta) {
    // Natural scrolling: content follows the fingers. 40 px = one notch.
    _wheelRemainder += fingerDelta * 3;
    final dx = _wheelRemainder.dx.truncate();
    final dy = _wheelRemainder.dy.truncate();
    if (dx.abs() >= 10 || dy.abs() >= 10) {
      s.wheel(-dx.toDouble(), dy.toDouble());
      _wheelRemainder -= Offset(dx.toDouble(), dy.toDouble());
    }
  }

  // ---- Pointer handling ----------------------------------------------------

  void _onDown(PointerDownEvent e) {
    final ptr = _Ptr(e.localPosition, e.kind);
    _pointers[e.pointer] = ptr;
    if (_pointers.length == 2) return _startTwo();
    if (_pointers.length > 2) return;

    if (touchHost) {
      if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
        s.nav('back');
        return;
      }
      if (e.kind == PointerDeviceKind.mouse && e.buttons == kMiddleMouseButton) {
        s.nav('home');
        return;
      }
      final n = _toRemote(e.localPosition);
      _fingerDown = true;
      s.touchDown(n.dx, n.dy);
      return;
    }

    if (e.kind == PointerDeviceKind.mouse) {
      final n = _toRemote(e.localPosition);
      s.moveTo(n.dx, n.dy);
      s.button(_mouseButton(e.buttons), true);
      return;
    }

    // Touch on a desktop host.
    if (widget.app.store.trackpadMode) {
      final last = _lastTapUp;
      if (last != null && DateTime.now().difference(last) < const Duration(milliseconds: 300)) {
        // Tap, then touch again: drag (or a double click if released quickly).
        _dragging = true;
        s.button(0, true);
      }
      _localCursor.value = _cursorNow;
    } else {
      _longPressFired = false;
      _longPress = Timer(const Duration(milliseconds: 500), () {
        if (ptr.travel < 10 && _pointers.length == 1) {
          _longPressFired = true;
          final n = _toRemote(ptr.position);
          s.moveTo(n.dx, n.dy);
          s.click(1);
          HapticFeedback.mediumImpact();
        }
      });
    }
  }

  int _mouseButton(int buttons) => switch (buttons) {
        kSecondaryMouseButton => 1,
        kMiddleMouseButton => 2,
        _ => 0,
      };

  int _lastButtons = 0;

  void _onMove(PointerMoveEvent e) {
    final ptr = _pointers[e.pointer];
    if (ptr == null) return;
    final delta = e.localPosition - ptr.position;
    ptr.position = e.localPosition;
    ptr.travel += delta.distance;

    if (_pointers.length == 2) return _moveTwo();
    if (_pointers.length > 2) return;

    if (touchHost) {
      final now = DateTime.now();
      if (_fingerDown && now.difference(_lastFingerMove).inMilliseconds >= 12) {
        final n = _toRemote(e.localPosition);
        s.touchMove(n.dx, n.dy);
        _lastFingerMove = now;
      }
      return;
    }

    if (e.kind == PointerDeviceKind.mouse) {
      final n = _toRemote(e.localPosition);
      _queueMove(n);
      return;
    }

    if (widget.app.store.trackpadMode) {
      final r = _display;
      final speed = widget.app.store.pointerSpeed;
      final c = _cursorNow;
      final n = Offset(
        (c.dx + delta.dx / r.width * speed).clamp(0.0, 1.0),
        (c.dy + delta.dy / r.height * speed).clamp(0.0, 1.0),
      );
      _localCursor.value = n;
      _queueMove(n);
      _followCursor(n);
    } else {
      if (_longPressFired) return;
      if (!_touchModeDragging && ptr.travel > 10) {
        _longPress?.cancel();
        _touchModeDragging = true;
        final start = _toRemote(ptr.start);
        s.moveTo(start.dx, start.dy);
        s.button(0, true);
      }
      if (_touchModeDragging) _queueMove(_toRemote(e.localPosition));
    }
  }

  void _onHover(PointerHoverEvent e) {
    if (touchHost || e.kind != PointerDeviceKind.mouse) return;
    _queueMove(_toRemote(e.localPosition));
  }

  void _onUp(PointerEvent e) {
    final ptr = _pointers.remove(e.pointer);
    if (ptr == null) return;
    final cancelled = e is PointerCancelEvent;

    if (_two != _Two.undecided || _twoStart != null) {
      if (_pointers.isEmpty) _endTwo(cancelled);
      return;
    }

    final held = DateTime.now().difference(ptr.startTime);
    final isTap = ptr.travel < 10 && held < const Duration(milliseconds: 250);

    if (touchHost) {
      if (e.kind == PointerDeviceKind.mouse && (_lastButtons & kSecondaryMouseButton) != 0) return;
      if (!_fingerDown) return;
      _fingerDown = false;
      final n = _toRemote(ptr.position);
      s.touchUp(n.dx, n.dy);
      return;
    }

    if (ptr.kind == PointerDeviceKind.mouse) {
      _flushMove();
      // Release every button; we do not know which one went up.
      for (final b in [0, 1, 2]) {
        s.button(b, false);
      }
      return;
    }

    if (widget.app.store.trackpadMode) {
      _flushMove();
      if (_dragging) {
        s.button(0, false);
        _dragging = false;
        _lastTapUp = null;
      } else if (isTap && !cancelled) {
        s.click();
        _lastTapUp = DateTime.now();
      }
      Future.delayed(const Duration(milliseconds: 800), () {
        if (_pointers.isEmpty && mounted) _localCursor.value = null;
      });
    } else {
      _longPress?.cancel();
      if (_touchModeDragging) {
        _flushMove();
        s.button(0, false);
        _touchModeDragging = false;
      } else if (!_longPressFired && isTap && !cancelled) {
        final n = _toRemote(ptr.position);
        s.moveTo(n.dx, n.dy);
        s.click();
      }
    }
  }

  // ---- Two fingers: scroll, pinch-zoom, right click -------------------------

  (Offset, double) _twoGeometry() {
    final ps = _pointers.values.toList();
    final center = (ps[0].position + ps[1].position) / 2;
    return (center, (ps[0].position - ps[1].position).distance);
  }

  void _startTwo() {
    _longPress?.cancel();
    if (_dragging) {
      s.button(0, false);
      _dragging = false;
    }
    if (_touchModeDragging) {
      s.button(0, false);
      _touchModeDragging = false;
    }
    if (_fingerDown) {
      // Second finger on a phone viewer: lift the first so it can't drag.
      final first = _pointers.values.first;
      final n = _toRemote(first.position);
      s.touchUp(n.dx, n.dy);
      _fingerDown = false;
    }
    final (c, d) = _twoGeometry();
    _two = _Two.undecided;
    _twoStart = DateTime.now();
    _twoStartDist = d;
    _twoStartScale = _view.value.scale;
    _twoLastCenter = c;
    _twoMoved = false;
    _wheelRemainder = Offset.zero;
  }

  void _moveTwo() {
    final (c, d) = _twoGeometry();
    final centerDelta = c - _twoLastCenter;
    _twoLastCenter = c;
    if (_two == _Two.undecided) {
      if ((d - _twoStartDist).abs() > 28) {
        _two = _Two.zoom;
      } else if ((c - _pointers.values.first.start).distance > 8 && !touchHost) {
        _two = _Two.scroll;
      } else if (touchHost && (d - _twoStartDist).abs() <= 28) {
        return;
      }
    }
    if (_two != _Two.undecided) _twoMoved = true;
    switch (_two) {
      case _Two.zoom:
        _zoomAbout(c, _twoStartScale * d / _twoStartDist);
        _panBy(centerDelta);
      case _Two.scroll:
        _sendWheel(centerDelta);
      case _Two.undecided:
        break;
    }
  }

  void _endTwo(bool cancelled) {
    final quick = _twoStart != null &&
        DateTime.now().difference(_twoStart!) < const Duration(milliseconds: 300);
    if (!touchHost && !_twoMoved && quick && !cancelled) {
      // Two-finger tap = right click (at the cursor or under the fingers).
      if (!widget.app.store.trackpadMode) {
        final n = _toRemote(_twoLastCenter);
        s.moveTo(n.dx, n.dy);
      }
      s.click(1);
    }
    _two = _Two.undecided;
    _twoStart = null;
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (touchHost) {
      // Mouse wheel on a phone = swipe.
      final start = _toRemote(e.localPosition);
      final dy = (-e.scrollDelta.dy / _display.height * 2.2).clamp(-0.45, 0.45);
      final end = Offset(start.dx, (start.dy + dy).clamp(0.02, 0.98));
      s.touch([start.dx, start.dy, end.dx, end.dy], 180);
    } else {
      s.wheel(-e.scrollDelta.dx * 1.2, -e.scrollDelta.dy * 1.2);
    }
  }

  // ---- Keyboard ------------------------------------------------------------

  void _toggleKeyboard() {
    if (_keyboardFocus.hasFocus) {
      _keyboardFocus.unfocus();
    } else {
      _keyboardFocus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    }
    setState(() {});
  }

  void _onTyping(String value) {
    if (value.length < _sentinel.length) {
      for (var i = 0; i < _sentinel.length - value.length; i++) {
        s.key('backspace');
      }
    } else if (value.length > _sentinel.length) {
      final added = value.substring(_sentinel.length);
      s.typeText(added);
    }
    _typing.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: _sentinel.length),
    );
  }

  static final _namedKeys = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.enter: 'enter',
    LogicalKeyboardKey.numpadEnter: 'enter',
    LogicalKeyboardKey.backspace: 'backspace',
    LogicalKeyboardKey.tab: 'tab',
    LogicalKeyboardKey.escape: 'escape',
    LogicalKeyboardKey.delete: 'delete',
    LogicalKeyboardKey.insert: 'insert',
    LogicalKeyboardKey.home: 'home',
    LogicalKeyboardKey.end: 'end',
    LogicalKeyboardKey.pageUp: 'pageup',
    LogicalKeyboardKey.pageDown: 'pagedown',
    LogicalKeyboardKey.arrowLeft: 'left',
    LogicalKeyboardKey.arrowRight: 'right',
    LogicalKeyboardKey.arrowUp: 'up',
    LogicalKeyboardKey.arrowDown: 'down',
    LogicalKeyboardKey.f1: 'f1', LogicalKeyboardKey.f2: 'f2',
    LogicalKeyboardKey.f3: 'f3', LogicalKeyboardKey.f4: 'f4',
    LogicalKeyboardKey.f5: 'f5', LogicalKeyboardKey.f6: 'f6',
    LogicalKeyboardKey.f7: 'f7', LogicalKeyboardKey.f8: 'f8',
    LogicalKeyboardKey.f9: 'f9', LogicalKeyboardKey.f10: 'f10',
    LogicalKeyboardKey.f11: 'f11', LogicalKeyboardKey.f12: 'f12',
  };

  /// Physical keyboard on the desktop viewer.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.handled;
    final hw = HardwareKeyboard.instance;
    final mods = [
      if (hw.isControlPressed) 'ctrl',
      if (hw.isAltPressed) 'alt',
      if (hw.isShiftPressed) 'shift',
      if (hw.isMetaPressed) 'win',
    ];
    final named = _namedKeys[e.logicalKey];
    if (named != null) {
      s.key(named, mods);
      return KeyEventResult.handled;
    }
    final ch = e.character;
    final chord = hw.isControlPressed || hw.isAltPressed || hw.isMetaPressed;
    if (!chord && ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 0x20) {
      s.typeText(ch);
      return KeyEventResult.handled;
    }
    final label = e.logicalKey.keyLabel;
    if (chord && label.length == 1) {
      s.key(label.toLowerCase(), mods);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- UI ------------------------------------------------------------------

  /// The interactive mirrored screen, sized to [size].
  Widget _screenSurface(Size size, {List<Rect> cutouts = const []}) {
    _layout(size);
    if (_view.value.scale != 1 || _view.value.offset != Offset.zero) {
      _view.value = _clamp(_view.value.scale, _view.value.offset);
    }
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _lastButtons = e.buttons;
        _onDown(e);
      },
      onPointerMove: _onMove,
      onPointerHover: _onHover,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      onPointerSignal: _onSignal,
      child: CustomPaint(
        size: size,
        painter: _ScreenPainter(
          frame: s.frame,
          cursor: s.cursor,
          localCursor: _localCursor,
          view: _view,
          display: () => _display,
          showCursor: !touchHost && phoneViewer,
          accent: Theme.of(context).colorScheme.primary,
          cutouts: cutouts,
          rounded: !touchHost,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!phoneViewer && touchHost) return _phoneWindow(context);
    final live = s.phase == SessionPhase.live;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _desktopFocus,
        onKeyEvent: phoneViewer ? null : _onKey,
        child: Stack(
          children: [
            Positioned.fill(
              child: LayoutBuilder(builder: (context, c) => _screenSurface(c.biggest)),
            ),
            _WaitingOverlay(frame: s.frame),
            // Hidden field that receives the phone's soft keyboard.
            Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: Opacity(
                opacity: 0,
                child: TextField(
                  focusNode: _keyboardFocus,
                  controller: _typing,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.send,
                  onChanged: _onTyping,
                  onSubmitted: (_) {
                    s.key('enter');
                    _keyboardFocus.requestFocus();
                  },
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _StatusChip(session: s),
                ),
              ),
            ),
            if (live && !s.inputAvailable)
              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 64, left: 16, right: 16),
                    child: Glass(
                      radius: 18,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Text(
                        'View only — turn on PixMirror remote control on ${s.hostName} to tap and type.',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _toolbar(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Phone mirror window (PC viewing a phone) ----------------------------

  static const _bezel = 11.0;

  /// Aspect of the mirrored phone right now (follows rotation).
  double get _phoneAspect {
    final img = s.frame.value;
    if (img != null) return img.width / img.height;
    final w = s.device['w'], h = s.device['h'];
    if (w is int && h is int && h > 0) return w / h;
    return s.screenHeight == 0 ? 9 / 19.5 : s.screenWidth / s.screenHeight;
  }

  Widget _phoneWindow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Aurora(
        child: Focus(
          focusNode: _desktopFocus,
          onKeyEvent: _onKey,
          child: Column(
            children: [
              _PhoneTitleBar(session: s, onClose: s.close),
              if (s.phase == SessionPhase.live && !s.inputAvailable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    'View only: turn on “PixMirror remote control” on ${s.hostName} to tap and type.',
                    style: text.bodySmall?.copyWith(color: scheme.error),
                    textAlign: TextAlign.center,
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  child: LayoutBuilder(builder: (context, c) => _phoneFrame(c)),
                ),
              ),
              Padding(padding: const EdgeInsets.only(bottom: 16), child: _toolbar()),
            ],
          ),
        ),
      ),
    );
  }

  static Rect _shrunk(Rect r, double f) =>
      Rect.fromCenter(center: r.center, width: r.width * f, height: r.height * f);

  Widget _phoneFrame(BoxConstraints c) {
    final aspect = _phoneAspect;
    var h = c.maxHeight - _bezel * 2;
    var w = h * aspect;
    if (w > c.maxWidth - _bezel * 2) {
      w = c.maxWidth - _bezel * 2;
      h = w / aspect;
    }
    if (w <= 0 || h <= 0) return const SizedBox.shrink();

    // Real corner radius and camera cutouts, scaled from physical pixels.
    final pw = (s.device['w'] as int?) ?? s.screenWidth;
    final ph = (s.device['h'] as int?) ?? s.screenHeight;
    final physLong = math.max(pw, ph).toDouble();
    final scale = physLong > 0 ? math.max(w, h) / physLong : 0.0;
    final corner = s.device['corner'];
    final radius = corner is int && corner > 0 ? corner * scale : math.min(w, h) * 0.09;
    final sameOrientation = (pw >= ph) == (w >= h);
    // Prefer the camera's exact shape (Android 12+). The older bounding rects
    // are padded safe zones, so shrink those toward the camera's center.
    final hole = (s.device['holes'] as List?)?.cast<num>();
    final raw = hole ?? (s.device['cutouts'] as List?)?.cast<num>() ?? const <num>[];
    final shrink = hole != null ? 1.0 : 0.55;
    final cutouts = <Rect>[
      if (sameOrientation && pw > 0 && ph > 0)
        for (var i = 0; i + 3 < raw.length; i += 4)
          _shrunk(Rect.fromLTRB(raw[i] / pw, raw[i + 1] / ph, raw[i + 2] / pw, raw[i + 3] / ph), shrink),
    ];

    return Center(
      child: Container(
        width: w + _bezel * 2,
        height: h + _bezel * 2,
        padding: const EdgeInsets.all(_bezel),
        decoration: BoxDecoration(
          color: const Color(0xFF0B0B0D),
          borderRadius: BorderRadius.circular(radius + _bezel),
          border: Border.all(color: const Color(0xFF3A3A40), width: 1.5),
          boxShadow: const [
            BoxShadow(color: Color(0x55000000), blurRadius: 40, offset: Offset(0, 18)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            children: [
              _screenSurface(Size(w, h), cutouts: cutouts),
              _WaitingOverlay(frame: s.frame),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final close = BarButton(
      icon: Icons.close_rounded,
      tooltip: 'Disconnect',
      onPressed: () => s.close(),
    );
    if (touchHost) {
      return GlassBar(children: [
        BarButton(icon: Icons.arrow_back_ios_new_rounded, tooltip: 'Back', onPressed: () => s.nav('back')),
        BarButton(icon: Icons.circle_outlined, tooltip: 'Home', onPressed: () => s.nav('home')),
        BarButton(icon: Icons.crop_square_rounded, tooltip: 'Recent apps', onPressed: () => s.nav('recents')),
        const _Divider(),
        if (phoneViewer)
          BarButton(
            icon: Icons.keyboard_rounded,
            tooltip: 'Keyboard',
            selected: _keyboardFocus.hasFocus,
            onPressed: _toggleKeyboard,
          ),
        BarButton(
          icon: Icons.apps_rounded,
          tooltip: 'More',
          onPressed: () => showKeysSheet(context, s),
        ),
        close,
      ]);
    }
    final store = widget.app.store;
    return GlassBar(children: [
      close,
      const _Divider(),
      if (phoneViewer) ...[
        BarButton(
          icon: Icons.keyboard_rounded,
          tooltip: 'Keyboard',
          selected: _keyboardFocus.hasFocus,
          onPressed: _toggleKeyboard,
        ),
        BarButton(
          icon: store.trackpadMode ? Icons.touch_app_rounded : Icons.ads_click_rounded,
          tooltip: store.trackpadMode ? 'Trackpad mode (tap to switch to touch)' : 'Touch mode (tap to switch to trackpad)',
          onPressed: () => setState(() => store.trackpadMode = !store.trackpadMode),
        ),
      ],
      BarButton(
        icon: Icons.keyboard_command_key_rounded,
        tooltip: 'Shortcuts',
        onPressed: () => showKeysSheet(context, s),
      ),
      if (s.monitors > 1)
        BarButton(
          icon: Icons.monitor_rounded,
          tooltip: 'Switch display',
          onPressed: () => s.selectMonitor((s.monitor + 1) % s.monitors),
        ),
      if (phoneViewer)
        BarButton(
          icon: Icons.zoom_out_map_rounded,
          tooltip: 'Fit to screen',
          onPressed: () => _view.value = _clamp(1, Offset.zero),
        ),
    ]);
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
      );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.session});

  final RemoteSession session;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Glass(
      radius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(color: Color(0xFF34C759), shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(session.hostName, style: text.labelLarge),
          ValueListenableBuilder<int>(
            valueListenable: session.fps,
            builder: (context, fps, _) => Text(
              '  ·  $fps fps',
              style: text.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaitingForScreen extends StatelessWidget {
  const _WaitingForScreen();

  @override
  Widget build(BuildContext context) => Glass(
        radius: 24,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 14),
            Text('Waiting for the screen…', style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      );
}

class _ScreenPainter extends CustomPainter {
  _ScreenPainter({
    required this.frame,
    required this.cursor,
    required this.localCursor,
    required this.view,
    required this.display,
    required this.showCursor,
    required this.accent,
    this.cutouts = const [],
    this.rounded = true,
  }) : super(repaint: Listenable.merge([frame, cursor, localCursor, view]));

  /// Camera cutouts, normalized to the screen; painted black like the glass.
  final List<Rect> cutouts;
  final bool rounded;

  final ValueNotifier<ui.Image?> frame;
  final ValueNotifier<CursorState?> cursor;
  final ValueNotifier<Offset?> localCursor;
  final ValueNotifier<_View> view;
  final Rect Function() display;
  final bool showCursor;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final image = frame.value;
    final dst = display();
    if (image != null) {
      final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
      canvas.save();
      if (rounded) canvas.clipRRect(RRect.fromRectAndRadius(dst, const Radius.circular(6)));
      canvas.drawImageRect(image, src, dst, Paint()..filterQuality = FilterQuality.medium);
      canvas.restore();
    }
    for (final c in cutouts) {
      final r = Rect.fromLTRB(
        dst.left + c.left * dst.width,
        dst.top + c.top * dst.height,
        dst.left + c.right * dst.width,
        dst.top + c.bottom * dst.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, Radius.circular(math.min(r.width, r.height) / 2)),
        Paint()..color = Colors.black,
      );
    }
    if (!showCursor) return;
    final local = localCursor.value;
    final remote = cursor.value;
    Offset? n;
    if (local != null) {
      n = local;
    } else if (remote != null && remote.kind != CursorKind.hidden) {
      n = Offset(remote.x, remote.y);
    }
    if (n == null) return;
    final p = Offset(dst.left + n.dx * dst.width, dst.top + n.dy * dst.height);
    _drawArrow(canvas, p, local != null);
  }

  void _drawArrow(Canvas canvas, Offset p, bool active) {
    final path = Path()
      ..moveTo(p.dx, p.dy)
      ..lineTo(p.dx, p.dy + 20)
      ..lineTo(p.dx + 5, p.dy + 15.5)
      ..lineTo(p.dx + 8.5, p.dy + 23)
      ..lineTo(p.dx + 11.5, p.dy + 21.5)
      ..lineTo(p.dx + 8, p.dy + 14.5)
      ..lineTo(p.dx + 14.5, p.dy + 14.5)
      ..close();
    canvas.drawShadow(path, Colors.black, 3, false);
    canvas.drawPath(path, Paint()..color = Colors.white);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round,
    );
    if (active) {
      canvas.drawCircle(p, 18, Paint()..color = accent.withValues(alpha: 0.22));
    }
  }

  @override
  bool shouldRepaint(_ScreenPainter old) =>
      old.showCursor != showCursor || old.accent != accent || old.cutouts != cutouts;
}

/// Small helper so other screens can animate into the viewer.
Route<void> viewerRoute(AppController app, RemoteSession session) => PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 450),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => ViewerScreen(app: app, session: session),
      transitionsBuilder: (context, animation, _, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.92, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );

/// Slim, draggable title bar for the phone mirror window.
class _PhoneTitleBar extends StatelessWidget {
  const _PhoneTitleBar({required this.session, required this.onClose});

  final RemoteSession session;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(color: Color(0xFF34C759), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(session.hostName, style: text.labelLarge, overflow: TextOverflow.ellipsis),
                    ),
                    ValueListenableBuilder<int>(
                      valueListenable: session.fps,
                      builder: (context, fps, _) => Text(
                        '  ·  $fps fps',
                        style: text.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Minimize',
            onPressed: () => windowManager.minimize(),
            icon: const Icon(Icons.remove_rounded, size: 18),
          ),
          IconButton(
            tooltip: 'Disconnect',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// "Waiting for the screen…" until the first frame arrives. Listens to the
/// frame itself: the viewer does not rebuild per frame, so a plain check in
/// build() would never notice the screen showing up.
class _WaitingOverlay extends StatelessWidget {
  const _WaitingOverlay({required this.frame});

  final ValueListenable<ui.Image?> frame;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ui.Image?>(
        valueListenable: frame,
        builder: (context, image, _) => IgnorePointer(
          ignoring: image != null,
          child: AnimatedOpacity(
            opacity: image == null ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: const Center(child: _WaitingForScreen()),
          ),
        ),
      );
}
