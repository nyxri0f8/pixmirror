import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/protocol.dart';
import '../widgets/glass_sheet.dart';
import 'guide_screen.dart';
import '../widgets/popups.dart';

Future<void> showSettings(BuildContext context, AppController app) => showGlassPanel(
      context,
      maxWidth: 560,
      builder: (context) => _Settings(app: app),
    );

class _Settings extends StatefulWidget {
  const _Settings({required this.app});
  final AppController app;

  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  late final _name = TextEditingController(text: widget.app.store.deviceName);

  @override
  void dispose() {
    widget.app.store.name = _name.text;
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.app.store;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 22, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 1.2),
          ),
        );

    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Settings', style: text.headlineMedium),
                const Spacer(),
                IconButton.filledTonal(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            section('This device'),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: 'Device name',
                helperText: 'Shown to your other devices',
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              ),
              onSubmitted: (v) => store.name = v,
            ),
            section('Streaming quality'),
            SegmentedButton<QualityPreset>(
              showSelectedIcon: false,
              segments: [
                for (final q in QualityPreset.values) ButtonSegment(value: q, label: Text(q.label)),
              ],
              selected: {store.quality},
              onSelectionChanged: (s) => store.quality = s.first,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                'Applies when this device shares its screen.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            section('Control'),
            if (!widget.app.isDesktop) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Trackpad mode'),
                subtitle: const Text('Drag to move the pointer, tap to click. Off: tap exactly where you touch.'),
                value: store.trackpadMode,
                onChanged: (v) => store.trackpadMode = v,
              ),
              Text('Pointer speed', style: text.bodyLarge),
              Slider(
                value: store.pointerSpeed,
                min: 0.6,
                max: 3,
                divisions: 12,
                label: '${store.pointerSpeed.toStringAsFixed(1)}×',
                onChanged: (v) => store.pointerSpeed = v,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  widget.app.phoneInputReady ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                  color: widget.app.phoneInputReady ? scheme.primary : scheme.error,
                ),
                title: const Text('Remote control of this phone'),
                subtitle: Text(widget.app.phoneInputReady
                    ? 'On. Your PC can tap, swipe and type here.'
                    : 'Off. Turn on "PixMirror remote control" in Accessibility. '
                        'If it is greyed out: App info > three-dot menu > Allow restricted settings.'),
                trailing: widget.app.phoneInputReady
                    ? null
                    : FilledButton.tonal(
                        onPressed: widget.app.openPhoneInputSettings,
                        child: const Text('Open'),
                      ),
              ),
            ] else ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Let paired devices control this PC'),
                subtitle: const Text('PixMirror keeps running in the tray so your phone can connect anytime.'),
                value: store.allowControl,
                onChanged: (v) => widget.app.setSharing(v),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Nearby device alerts'),
              subtitle: const Text('Pop up when a paired device is ready to connect'),
              value: store.notifyNearby,
              onChanged: (v) => store.notifyNearby = v,
            ),
            if (!widget.app.isDesktop)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.auto_stories_rounded),
                title: const Text('Setup guide'),
                subtitle: const Text('Restricted settings, accessibility and notifications, step by step'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (ctx) => SetupGuideScreen(
                      app: widget.app,
                      onDone: () => Navigator.of(ctx).pop(),
                    ),
                  ));
                },
              ),
            section('Appearance'),
            SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('Auto'), icon: Icon(Icons.brightness_auto_rounded)),
                ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_rounded)),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_rounded)),
              ],
              selected: {store.themeMode},
              onSelectionChanged: (s) => store.themeMode = s.first,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Reduce transparency'),
              subtitle: const Text('Use solid surfaces instead of glass'),
              value: store.reduceTransparency,
              onChanged: (v) => store.reduceTransparency = v,
            ),
            section('Paired devices'),
            if (store.trusted.isEmpty)
              Text('No paired devices yet.', style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant))
            else
              for (final d in store.trusted)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(deviceIcon(d.platform)),
                  title: Text(d.name),
                  trailing: TextButton(
                    onPressed: () => store.forget(d.id),
                    child: const Text('Forget'),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
