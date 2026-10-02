import 'dart:async';
import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_controller.dart';
import 'core/store.dart';
import 'desktop/desktop_shell.dart';
import 'platform/android_host.dart';
import 'screens/guide_screen.dart';
import 'screens/home_screen.dart';
import 'screens/splash_screen.dart';
import 'ui/glass.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DesktopShell.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const PixMirrorApp());
}

/// Starts everything behind the splash: identity, discovery, host server.
Future<AppController> _boot() async {
  final defaultName = Platform.isAndroid
      ? await native.invokeMethod<String>('deviceName') ?? 'Android phone'
      : Platform.localHostname;
  final store = await Store.load(defaultName: defaultName);
  final app = AppController(store);
  await app.init();
  await DesktopShell.instance.attach(app);
  return app;
}

enum _Stage { splash, guide, home }

final _idle = ValueNotifier(0);

class PixMirrorApp extends StatefulWidget {
  const PixMirrorApp({super.key});

  @override
  State<PixMirrorApp> createState() => _PixMirrorAppState();
}

class _PixMirrorAppState extends State<PixMirrorApp> {
  late final Future<AppController> _booting = _boot();
  AppController? _app;
  _Stage _stage = _Stage.splash;

  @override
  void initState() {
    super.initState();
    _booting.then((app) => setState(() => _app = app));
  }

  void _afterSplash() {
    final app = _app!;
    setState(() {
      _stage = Platform.isAndroid && !app.store.onboarded ? _Stage.guide : _Stage.home;
    });
  }

  void _afterGuide() {
    _app!.store.onboarded = true;
    setState(() => _stage = _Stage.home);
  }

  @override
  Widget build(BuildContext context) {
    final store = _app?.store;
    return ListenableBuilder(
      listenable: store ?? _idle,
      builder: (context, _) => DynamicColorBuilder(
        builder: (light, dark) => MaterialApp(
          title: 'PixMirror',
          debugShowCheckedModeBanner: false,
          themeMode: store?.themeMode ?? ThemeMode.system,
          theme: buildTheme(light, Brightness.light),
          darkTheme: buildTheme(dark, Brightness.dark),
          builder: (context, child) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
              systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            ));
            return GlassScope(
              reduceTransparency: store?.reduceTransparency ?? false,
              child: child!,
            );
          },
          home: AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween(begin: 1.04, end: 1.0).animate(animation),
                child: child,
              ),
            ),
            child: switch (_stage) {
              _Stage.splash => SplashScreen(
                  key: const ValueKey('splash'),
                  ready: _booting,
                  onDone: _afterSplash,
                ),
              _Stage.guide => SetupGuideScreen(
                  key: const ValueKey('guide'),
                  app: _app!,
                  onDone: _afterGuide,
                ),
              _Stage.home => HomeScreen(key: const ValueKey('home'), app: _app!),
            },
          ),
        ),
      ),
    );
  }
}
