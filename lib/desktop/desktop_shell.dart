import 'dart:io';

import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import '../core/app_controller.dart';

/// Windows integration: frameless window, close-to-tray, tray menu and
/// toast notifications. Everything is a no-op on Android.
class DesktopShell with WindowListener {
  DesktopShell._();
  static final instance = DesktopShell._();

  bool get enabled => Platform.isWindows;
  AppController? _app;
  bool _visible = true;
  bool _toldAboutTray = false;
  tray.TrayIcon? _tray;
  tray.MenuItem? _allowItem;

  bool get visible => !enabled || _visible;

  static Future<void> ensureInitialized() async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    await localNotifier.setup(appName: 'PixMirror', shortcutPolicy: ShortcutPolicy.requireCreate);
    const options = WindowOptions(
      size: Size(1080, 720),
      minimumSize: Size(380, 560),
      center: true,
      title: 'PixMirror',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    await windowManager.setPreventClose(true);
  }

  Future<void> attach(AppController app) async {
    if (!enabled) return;
    _app = app;
    windowManager.addListener(this);

    final icon = tray.TrayIcon.create();
    if (icon == null) return;
    _tray = icon;
    icon.icon = tray.ImageAsset.fromAsset('assets/tray.png');
    icon.setTooltip('PixMirror');

    final menu = tray.Menu.create()!;
    menu.addItem(_item('Open PixMirror', show));
    menu.addSeparator();
    _allowItem = _item(
      'Allow paired devices to connect',
      () => app.setSharing(!app.store.allowControl),
      type: tray.MenuItemType.checkbox,
    );
    menu.addItem(_allowItem);
    menu.addSeparator();
    menu.addItem(_item('Quit', _quit));
    icon.setContextMenu(menu);
    icon.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
    icon.addListener((event) {
      if (event is tray.TrayIconClickedEvent || event is tray.TrayIconDoubleClickedEvent) show();
    });
    icon.setVisible(true);

    _syncMenu();
    app.store.addListener(_syncMenu);
  }

  tray.MenuItem? _item(String label, void Function() onClick,
      {tray.MenuItemType type = tray.MenuItemType.normal}) {
    final item = tray.MenuItem.createWithLabelAndType(label, type);
    item?.addListener((event) {
      if (event is tray.MenuItemClickedEvent) onClick();
    });
    return item;
  }

  void _syncMenu() {
    _allowItem?.state = (_app?.store.allowControl ?? true)
        ? tray.MenuItemState.checked
        : tray.MenuItemState.unchecked;
  }

  Future<void> _quit() async {
    _tray?.setVisible(false);
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  Future<void> show() async {
    if (!enabled) return;
    await windowManager.show();
    await windowManager.focus();
    _visible = true;
  }

  Future<void> toast(String title, String body, {VoidCallback? onClick}) async {
    if (!enabled) return;
    final n = LocalNotification(title: title, body: body);
    n.onClick = () {
      show();
      onClick?.call();
    };
    await n.show();
  }

  @override
  void onWindowClose() async {
    // Closing hides to the tray so phones can still reach this PC.
    await windowManager.hide();
    _visible = false;
    if (!_toldAboutTray) {
      _toldAboutTray = true;
      toast('PixMirror is still running', 'Your phone can connect anytime. Quit from the tray icon.');
    }
  }

  @override
  void onWindowFocus() => _visible = true;

}

/// Frameless title bar: drag area plus Windows 11 caption buttons.
class TitleBar extends StatelessWidget {
  const TitleBar({super.key, this.title});

  final String? title;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title ?? '',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
          _CaptionButton(icon: Icons.remove_rounded, onTap: () => windowManager.minimize()),
          _CaptionButton(
            icon: Icons.crop_square_rounded,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                windowManager.unmaximize();
              } else {
                windowManager.maximize();
              }
            },
          ),
          _CaptionButton(icon: Icons.close_rounded, onTap: () => windowManager.close(), danger: true),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({required this.icon, required this.onTap, this.danger = false});
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = !_hover
        ? Colors.transparent
        : widget.danger
            ? const Color(0xFFE81123)
            : scheme.onSurface.withValues(alpha: 0.08);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 46,
          height: 40,
          color: bg,
          child: Icon(
            widget.icon,
            size: 16,
            color: _hover && widget.danger ? Colors.white : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
