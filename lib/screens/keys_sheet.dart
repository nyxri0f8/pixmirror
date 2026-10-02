import 'package:flutter/material.dart';

import '../core/remote_session.dart';
import '../widgets/glass_sheet.dart';

class _Shortcut {
  const _Shortcut(this.label, this.icon, this.run);
  final String label;
  final IconData icon;
  final void Function(RemoteSession s) run;
}

_Shortcut _combo(String label, IconData icon, String key, [List<String> mods = const []]) =>
    _Shortcut(label, icon, (s) => s.key(key, mods));

final _desktopGroups = <String, List<_Shortcut>>{
  'Mouse': [
    _Shortcut('Right click', Icons.mouse_rounded, (s) => s.click(1)),
    _Shortcut('Double click', Icons.ads_click_rounded, (s) => s..click()..click()),
    _Shortcut('Middle click', Icons.radio_button_checked_rounded, (s) => s.click(2)),
  ],
  'Edit': [
    _combo('Copy', Icons.content_copy_rounded, 'c', ['ctrl']),
    _combo('Paste', Icons.content_paste_rounded, 'v', ['ctrl']),
    _combo('Cut', Icons.content_cut_rounded, 'x', ['ctrl']),
    _combo('Undo', Icons.undo_rounded, 'z', ['ctrl']),
    _combo('Redo', Icons.redo_rounded, 'y', ['ctrl']),
    _combo('Select all', Icons.select_all_rounded, 'a', ['ctrl']),
    _combo('Save', Icons.save_rounded, 's', ['ctrl']),
    _combo('Find', Icons.search_rounded, 'f', ['ctrl']),
  ],
  'Windows': [
    _combo('Start', Icons.window_rounded, '', ['win']),
    _combo('Switch app', Icons.swap_horiz_rounded, 'tab', ['alt']),
    _combo('Task view', Icons.view_carousel_rounded, 'tab', ['win']),
    _combo('Desktop', Icons.desktop_windows_rounded, 'd', ['win']),
    _combo('Close app', Icons.close_rounded, 'f4', ['alt']),
    _combo('Snip', Icons.screenshot_monitor_rounded, 's', ['win', 'shift']),
    _combo('Task Manager', Icons.monitor_heart_rounded, 'escape', ['ctrl', 'shift']),
    _combo('Emoji', Icons.emoji_emotions_rounded, '.', ['win']),
  ],
  'Keys': [
    _combo('Esc', Icons.cancel_outlined, 'escape'),
    _combo('Tab', Icons.keyboard_tab_rounded, 'tab'),
    _combo('Enter', Icons.keyboard_return_rounded, 'enter'),
    _combo('Delete', Icons.backspace_outlined, 'delete'),
    _combo('Left', Icons.arrow_back_rounded, 'left'),
    _combo('Up', Icons.arrow_upward_rounded, 'up'),
    _combo('Down', Icons.arrow_downward_rounded, 'down'),
    _combo('Right', Icons.arrow_forward_rounded, 'right'),
    _combo('Home', Icons.first_page_rounded, 'home'),
    _combo('End', Icons.last_page_rounded, 'end'),
    _combo('Page up', Icons.keyboard_double_arrow_up_rounded, 'pageup'),
    _combo('Page down', Icons.keyboard_double_arrow_down_rounded, 'pagedown'),
    _combo('Refresh', Icons.refresh_rounded, 'f5'),
    _combo('Full screen', Icons.fullscreen_rounded, 'f11'),
  ],
  'Media': [
    _combo('Volume down', Icons.volume_down_rounded, 'volumedown'),
    _combo('Volume up', Icons.volume_up_rounded, 'volumeup'),
    _combo('Mute', Icons.volume_off_rounded, 'volumemute'),
    _combo('Play / pause', Icons.play_arrow_rounded, 'mediaplay'),
    _combo('Next', Icons.skip_next_rounded, 'medianext'),
  ],
};

final _phoneGroups = <String, List<_Shortcut>>{
  'Navigate': [
    _Shortcut('Back', Icons.arrow_back_ios_new_rounded, (s) => s.nav('back')),
    _Shortcut('Home', Icons.circle_outlined, (s) => s.nav('home')),
    _Shortcut('Recents', Icons.crop_square_rounded, (s) => s.nav('recents')),
  ],
  'System': [
    _Shortcut('Notifications', Icons.notifications_rounded, (s) => s.nav('notifications')),
    _Shortcut('Quick settings', Icons.tune_rounded, (s) => s.nav('quickSettings')),
    _Shortcut('Screenshot', Icons.screenshot_rounded, (s) => s.nav('screenshot')),
    _Shortcut('Lock', Icons.lock_rounded, (s) => s.nav('lock')),
  ],
  'Typing': [
    _Shortcut('Enter', Icons.keyboard_return_rounded, (s) => s.key('enter')),
    _Shortcut('Backspace', Icons.backspace_outlined, (s) => s.key('backspace')),
  ],
};

Future<void> showKeysSheet(BuildContext context, RemoteSession session) {
  final groups = session.isTouchHost ? _phoneGroups : _desktopGroups;
  return showGlassPanel(
    context,
    maxWidth: 560,
    builder: (context) {
      final text = Theme.of(context).textTheme;
      final scheme = Theme.of(context).colorScheme;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session.isTouchHost ? 'Phone controls' : 'Shortcuts', style: text.titleLarge),
            for (final entry in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 18, bottom: 10),
                child: Text(
                  entry.key.toUpperCase(),
                  style: text.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final sc in entry.value)
                    ActionChip(
                      avatar: Icon(sc.icon, size: 18),
                      label: Text(sc.label),
                      shape: const StadiumBorder(),
                      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
                      onPressed: () {
                        Navigator.of(context).pop();
                        sc.run(session);
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      );
    },
  );
}
