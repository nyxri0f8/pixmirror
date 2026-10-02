// Renders real PixMirror screens to PNG for docs and videos — no device needed.
//
//   flutter test test/screenshots_test.dart
//
// Output: build/screenshots/*.png (phone shots at Pixel 7 resolution).

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixmirror/core/app_controller.dart';
import 'package:pixmirror/core/discovery.dart';
import 'package:pixmirror/core/host_server.dart';
import 'package:pixmirror/core/protocol.dart';
import 'package:pixmirror/core/remote_session.dart';
import 'package:pixmirror/core/store.dart';
import 'package:pixmirror/platform/screen_host.dart';
import 'package:pixmirror/screens/guide_screen.dart';
import 'package:pixmirror/screens/home_screen.dart';
import 'package:pixmirror/screens/splash_screen.dart';
import 'package:pixmirror/screens/viewer_screen.dart';
import 'package:pixmirror/ui/glass.dart';
import 'package:pixmirror/ui/theme.dart';
import 'package:pixmirror/widgets/popups.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Host extends ScreenHost {
  _Host(this.platform);
  @override
  final String platform;
  @override
  bool get running => false;
  @override
  Stream<void> get stopped => const Stream.empty();
  @override
  Future<bool> start(QualityPreset quality) async => true;
  @override
  Future<void> stop() async {}
  @override
  void configure(QualityPreset quality) {}
  @override
  Future<Frame?> nextFrame({bool force = false}) async => null;
  @override
  (int, int) get screenSize => (1080, 2400);
  @override
  Future<bool> inputAvailable() async => true;
  @override
  void handleInput(Map<String, dynamic> msg) {}
}

const _flutterFonts = 'C:/Users/nyx41/flutter/bin/cache/artifacts/material_fonts';
final _out = Directory('build/screenshots');
final _key = GlobalKey();

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  await family('Roboto', [
    '$_flutterFonts/roboto-regular.ttf',
    '$_flutterFonts/roboto-medium.ttf',
    '$_flutterFonts/roboto-bold.ttf',
  ]);
  await family('MaterialIcons', ['$_flutterFonts/materialicons-regular.otf']);
}

Peer _peer(String id, String name, String platform, {bool sharing = true}) => Peer(
      id: id,
      name: name,
      platform: platform,
      address: InternetAddress('192.168.1.15'),
      port: kHostPort,
      sharing: sharing,
      lastSeen: DateTime.now(),
    );

Widget _app(Widget home, {Brightness brightness = Brightness.dark}) => RepaintBoundary(
      key: _key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(null, brightness),
        builder: (context, child) => GlassScope(reduceTransparency: false, child: child!),
        home: home,
      ),
    );

Future<void> _snap(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 900));
  await tester.runAsync(() async {
    final boundary = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    _out.createSync(recursive: true);
    File('${_out.path}/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void _phone(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2400);
  t.view.devicePixelRatio = 2.625;
}

/// PC shots at 1.5x so they stay sharp on a 1080p video.
void _pc(WidgetTester t, [Size size = const Size(1280, 800)]) {
  t.view.physicalSize = size * 1.5;
  t.view.devicePixelRatio = 1.5;
}

late Store store;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    store = await Store.load(defaultName: 'Pixel 7');
    await _loadFonts();
  });

  AppController phoneApp({bool inputReady = true}) {
    final app = AppController(store, host: _Host('android'), desktop: false)
      ..initOffline(peers: [_peer('tqCvVYXdvaML0fL0DMCV', 'nyx', 'windows')])
      ..phoneInputReady = inputReady;
    store.trust(TrustedDevice(id: 'tqCvVYXdvaML0fL0DMCV', name: 'nyx', platform: 'windows', publicKey: 'AA=='));
    return app;
  }

  AppController pcApp() {
    store.trust(TrustedDevice(id: 'Q2d8iI6HdVlIfg7xYzAb', name: 'Pixel 7', platform: 'android', publicKey: 'AA=='));
    return AppController(store, host: _Host('windows'), desktop: true)
      ..initOffline(peers: [_peer('Q2d8iI6HdVlIfg7xYzAb', 'Pixel 7', 'android', sharing: false)]);
  }

  testWidgets('phone: splash', (t) async {
    _phone(t);
    await t.pumpWidget(_app(SplashScreen(ready: Completer<void>().future, onDone: () {})));
    final ctx = t.element(find.byType(SplashScreen));
    await t.runAsync(() => precacheImage(const AssetImage('assets/logo.png'), ctx));
    await t.pump(const Duration(milliseconds: 1200));
    await _snap(t, 'phone_splash');
  });

  testWidgets('phone: home', (t) async {
    _phone(t);
    await t.pumpWidget(_app(HomeScreen(app: phoneApp())));
    await _snap(t, 'phone_home');
  });

  testWidgets('phone: setup guide pages', (t) async {
    _phone(t);
    final app = phoneApp(inputReady: false);
    await t.pumpWidget(_app(SetupGuideScreen(app: app, onDone: () {})));
    await _snap(t, 'phone_setup_welcome');
    for (final name in ['phone_setup_how', 'phone_setup_restricted', 'phone_setup_accessibility']) {
      await t.tap(find.text('Next'));
      await t.pump(const Duration(milliseconds: 700));
      await _snap(t, name);
    }
  });

  testWidgets('phone: share request', (t) async {
    _phone(t);
    final app = phoneApp();
    await t.pumpWidget(_app(HomeScreen(app: app)));
    final ctx = t.element(find.byType(HomeScreen));
    unawaited(showShareRequest(ctx, app, ShareRequest('nyx')));
    await t.pump(const Duration(milliseconds: 800));
    await _snap(t, 'phone_share_request');
  });

  testWidgets('phone: pairing code', (t) async {
    _phone(t);
    final app = phoneApp();
    await t.pumpWidget(_app(HomeScreen(app: app)));
    final session = RemoteSession(peer: _peer('tqCvVYXdvaML0fL0DMCV', 'nyx', 'windows'), store: store)
      ..pairCode = '401207'
      ..phase = SessionPhase.awaitingApproval;
    unawaited(showConnectPanel(t.element(find.byType(HomeScreen)), session));
    await t.pump(const Duration(milliseconds: 800));
    await _snap(t, 'phone_pairing');
  });

  testWidgets('pc: home', (t) async {
    _pc(t);
    await t.pumpWidget(_app(HomeScreen(app: pcApp())));
    await _snap(t, 'pc_home');
  });

  testWidgets('pc: pairing prompt', (t) async {
    _pc(t);
    final app = pcApp();
    await t.pumpWidget(_app(HomeScreen(app: app)));
    unawaited(showPairPrompt(t.element(find.byType(HomeScreen)), app.server, PairRequest('x', 'Pixel 7', 'android', '401207')));
    await t.pump(const Duration(milliseconds: 800));
    await _snap(t, 'pc_pairing');
  });

  testWidgets('pc: how it works', (t) async {
    _pc(t);
    final app = pcApp();
    await t.pumpWidget(_app(HomeScreen(app: app)));
    unawaited(showHowItWorks(t.element(find.byType(HomeScreen)), app));
    await t.pump(const Duration(milliseconds: 800));
    await _snap(t, 'pc_how_it_works');
  });

  testWidgets('pc: phone mirror window', (t) async {
    _pc(t, const Size(470, 1000));
    final app = pcApp();
    final session = RemoteSession(peer: _peer('Q2d8iI6HdVlIfg7xYzAb', 'Pixel 7', 'android'), store: store)
      ..hostName = 'Pixel 7'
      ..hostPlatform = 'android'
      ..screenWidth = 1080
      ..screenHeight = 2400
      ..device = {'w': 1080, 'h': 2400, 'corner': 110, 'holes': [494.0, 38.0, 586.0, 130.0]}
      ..phase = SessionPhase.live;
    // Mirror the phone's own PixMirror home screen inside the PC window.
    final shot = File('${_out.path}/phone_home.png');
    if (shot.existsSync()) {
      await t.runAsync(() async {
        final codec = await ui.instantiateImageCodec(shot.readAsBytesSync());
        session.frame.value = (await codec.getNextFrame()).image;
      });
    }
    session.fps.value = 30;
    await t.pumpWidget(_app(ViewerScreen(app: app, session: session)));
    await _snap(t, 'pc_mirror_window');
  });
}
