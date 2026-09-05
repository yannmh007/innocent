import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'player_controls_screen.dart';
import 'player_navigation_screen.dart';
import 'player_screen_settings_screen.dart';
import 'player_style_screen.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > Player — full MX Player parity (UI PDF page 15)
/// Sections: Interface, Playback, Background Play, Miscellaneous
///
/// Phase 40: All 23 toggles now persist via [playerSettingsProvider]. Before,
/// each was a widget-local `bool` that reset to its default on every screen
/// open — meaning the user's choices were silently thrown away. Now every
/// toggle reads from and writes to SharedPreferences.
class SettingsPlayerScreen extends ConsumerWidget {
  const SettingsPlayerScreen({super.key});

  void _openSub(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// Builds a [SettingsToggleTile] backed by [playerSettingsProvider].
  Widget _toggle(
    WidgetRef ref, {
    required String title,
    String? subtitle,
    required PlayerSetting setting,
  }) {
    final value = ref.watch(playerSettingsProvider).get(setting);
    return SettingsToggleTile(
      title: title,
      subtitle: subtitle,
      value: value,
      onChanged: (v) =>
          ref.read(playerSettingsProvider.notifier).setValue(setting, v),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).settingsPlayer)),
      body: ListView(
        children: [
          const SettingsSectionHeader('Interface'),
          SettingsNavTile(
            title: 'Style',
            onTap: () => _openSub(context, const PlayerStyleScreen()),
          ),
          SettingsNavTile(
            title: 'Screen',
            subtitle:
                'Screen settings: Orientation, Full Screen, Brightness, etc.',
            onTap: () =>
                _openSub(context, const PlayerScreenSettingsScreen()),
          ),
          SettingsNavTile(
            title: 'Controls',
            subtitle:
                'Input controls: Touch actions, gestures, lock mode, etc.',
            onTap: () => _openSub(context, const PlayerControlsScreen()),
          ),
          SettingsNavTile(
            title: 'Navigation',
            subtitle:
                'Navigation settings: seeking settings, forward/backward buttons, etc.',
            onTap: () => _openSub(context, const PlayerNavigationScreen()),
          ),
          _toggle(ref,
              title: 'Double-tap the back button',
              subtitle: 'Press the back button twice to close playback screen.',
              setting: PlayerSetting.doubleTapBack),
          _toggle(ref,
              title: 'Quick zoom',
              subtitle:
                  "Skip zoom steps between 100% and 'fit to screen' (150%, 200%, etc).",
              setting: PlayerSetting.quickZoom),
          // Audit fix (A4): pin the player controls so they never
          // auto-hide. Useful for tutorial recordings or anyone who
          // wants the timestamp permanently in view.
          _toggle(ref,
              title: 'Pin controls (always visible)',
              subtitle:
                  'When on, the player controls never auto-hide. Useful while presenting or for sustained at-a-glance time-checking. Off by default.',
              setting: PlayerSetting.alwaysShowControls),
          // Audit fix (A2): user-tunable auto-hide delay. Hidden when
          // [alwaysShowControls] is on since the value is irrelevant
          // then.
          Builder(builder: (ctx) {
            final pinned = ref
                .watch(playerSettingsProvider)
                .get(PlayerSetting.alwaysShowControls);
            if (pinned) return const SizedBox.shrink();
            final current = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.controlsHideDelay);
            return SettingsNavTile(
              title: 'Controls auto-hide delay',
              subtitle:
                  'How long the playback controls stay visible after the last touch. Currently: ${current}s. Range 2-15s.',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Auto-hide delay',
                  options: const ['2', '3', '4', '5', '6', '8', '10', '15'],
                  currentValue: current.toString(),
                );
                if (picked == null) return;
                final v = int.tryParse(picked);
                if (v == null) return;
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setInt(IntSetting.controlsHideDelay, v);
              },
            );
          }),
          const SettingsSectionHeader('Playback'),
          Builder(builder: (ctx) {
            // Phase 45 (audit): MX Player V3 `resume_last` setting has
            // 3 values: 'ask' (default), 'resume', 'startover'. We
            // surface those exactly with MX Player's wording.
            final current = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.resumeLast);
            final label = current == 'resume'
                ? 'Always (Resume)'
                : current == 'startover'
                    ? 'Never (Start over)'
                    : 'Ask every time';
            return SettingsNavTile(
              title: 'Resume',
              subtitle:
                  'Select whether to resume from the point where you stopped. Currently: $label',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Resume',
                  options: const [
                    'Ask every time',
                    'Always (Resume)',
                    'Never (Start over)',
                  ],
                  currentValue: label,
                );
                if (picked == null) return;
                final next = picked == 'Always (Resume)'
                    ? 'resume'
                    : picked == 'Never (Start over)'
                        ? 'startover'
                        : 'ask';
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setStr(StringSetting.resumeLast, next);
              },
            );
          }),
          _toggle(ref,
              title: 'Resume only the first file',
              subtitle:
                  'Apply resume setting only on the first file. Next files will start from the beginning.',
              setting: PlayerSetting.resumeOnlyFirst),
          Builder(builder: (ctx) {
            // Phase 45 (audit): MX Player V3 stores default playback
            // speed as an integer percent 25..400 (default 100). We
            // display as a multiplier and persist as int.
            final pct = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.defaultPlaybackSpeed);
            return SettingsNavTile(
              title: 'Default playback speed',
              subtitle: '${(pct / 100).toStringAsFixed(2)}x',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Default Playback Speed',
                  currentValue: pct / 100.0,
                  min: 0.25,
                  max: 4.0,
                  divisions: 15,
                  valueLabel: (v) => '${v.toStringAsFixed(2)}x',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setInt(IntSetting.defaultPlaybackSpeed,
                          (picked * 100).round());
                }
              },
            );
          }),
          _toggle(ref,
              title: 'Remember selections',
              subtitle:
                  'Remember selections for each files such as choice of audio track, subtitle track, decoder.',
              setting: PlayerSetting.rememberSelections),
          _toggle(ref,
              title: 'Back to list',
              subtitle: 'Return to the list after playback is completed.',
              setting: PlayerSetting.backToList),
          _toggle(ref,
              title: 'Preview while seeking',
              subtitle:
                  'Display preview image while changing playback position.',
              setting: PlayerSetting.previewSeek),
          _toggle(ref,
              title: 'Preview while seeking (network)',
              subtitle: 'Display preview image for network play.',
              setting: PlayerSetting.previewSeekNetwork),
          _toggle(ref,
              title: 'Fast seeking',
              subtitle:
                  'Seek to nearest key-frame position instead of exact position. This setting applies to HW+ and SW decoder.',
              setting: PlayerSetting.fastSeeking),
          _toggle(ref,
              title: 'Play alone',
              subtitle:
                  'Stop other players while playing back videos or audios. It also makes MX Player stop if other players begin to play or you make a phone call.',
              setting: PlayerSetting.playAlone),
          _toggle(ref,
              title: 'Media buttons',
              subtitle:
                  'Respond to media control buttons from headset, Bluetooth, etc.',
              setting: PlayerSetting.mediaButtons),
          // Phase 45 (audit refined, build 63): MX Player V3's
          // `honour_headset_hook_multi_press`. Wired as a boolean
          // toggle (was visible-only list dialog).
          _toggle(ref,
              title: 'Double/Triple press → Next/Prev',
              subtitle:
                  'Treat double/triple presses on the headphone button as Next/Previous track.',
              setting: PlayerSetting.honourHeadsetMultiPress),
          // Phase 45 (audit refined, build 64): wire Next/Prev → FF/Rew
          // to PlayerSetting.customPopupFastForward (already exists
          // for the custom pop-up; we reuse it for the global media
          // button mapping policy — same semantic).
          _toggle(ref,
              title: 'Next/Prev \u2192 FF/Rew',
              subtitle:
                  'Treat Next/Prev media buttons as Fast Forward / Rewind.',
              setting: PlayerSetting.customPopupFastForward),
          _toggle(ref,
              title: 'Toggle playback with play button',
              subtitle:
                  "Toggle playback in response to 'play' media button. This option is useful only for devices having trouble with the play button.",
              setting: PlayerSetting.togglePlayback),
          _toggle(ref,
              title: 'Smart Previous Button',
              subtitle:
                  "If you select 'previous' button, it will resume again from the beginning or open the previous file depending upon the current playback position.",
              setting: PlayerSetting.smartPrevious),
          _toggle(ref,
              title: 'Suppress error message',
              subtitle:
                  'Skip to next video without displaying error message if video loading fails.',
              setting: PlayerSetting.suppressError),
          _toggle(ref,
              title: 'Use custom Picture-in-Picture popup',
              subtitle: 'Use custom Picture-in-Picture resizable popup.',
              setting: PlayerSetting.useCustomPip),
          const SettingsSectionHeader('Background Play'),
          // Phase 45 (audit): MX Player V3 `sticky_video` is a 3-choice
          // setting: 'stop', 'background', 'pip' (default). Replaces our
          // earlier boolean Background/PIP toggle.
          Builder(builder: (ctx) {
            final current = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.stickyVideo);
            final label = current == 'stop'
                ? 'Stop'
                : current == 'background'
                    ? 'Play in background'
                    : 'Picture-in-Picture';
            return SettingsNavTile(
              title: 'Background/PIP mode',
              subtitle:
                  'Player behavior when switching to another app. Currently: $label',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Background / PiP',
                  options: const [
                    'Picture-in-Picture',
                    'Play in background',
                    'Stop',
                  ],
                  currentValue: label,
                );
                if (picked == null) return;
                final next = picked == 'Stop'
                    ? 'stop'
                    : picked == 'Play in background'
                        ? 'background'
                        : 'pip';
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setStr(StringSetting.stickyVideo, next);
              },
            );
          }),
          _toggle(ref,
              title: 'Background play (audio)',
              subtitle: 'Use Background play for audio playback.',
              setting: PlayerSetting.bgPlayAudio),
          _toggle(ref,
              title: 'Album art',
              subtitle: 'Display cover art on the lock screen.',
              setting: PlayerSetting.albumArt),
          _toggle(ref,
              title: 'Smooth switch',
              subtitle:
                  'Fade in and out audio when switching to and return back from background play.',
              setting: PlayerSetting.smoothSwitch),
          const SettingsSectionHeader('Miscellaneous'),
          // Phase 45 (audit): MX Player `video_zoom_delay` is in
          // milliseconds (0..2000). We surface it as a 0..2 second
          // slider for friendlier UX and convert to int ms when saving.
          Builder(builder: (ctx) {
            final ms = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.videoZoomDelay);
            return SettingsNavTile(
              title: 'Video resizing delay',
              subtitle:
                  'Delay before HW resize kicks in. Higher = fewer flickers. Currently: ${ms}ms',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Video Resizing Delay',
                  currentValue: ms / 1000.0,
                  min: 0.0,
                  max: 2.0,
                  divisions: 20,
                  valueLabel: (v) => '${(v * 1000).round()}ms',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setInt(IntSetting.videoZoomDelay,
                          (picked * 1000).round());
                }
              },
            );
          }),
          _toggle(ref,
              title: 'Limit Video Resizing',
              subtitle:
                  'Do not increase video size if it exceeds its display size. (HW decoder only)',
              setting: PlayerSetting.limitResize),
          _toggle(ref,
              title: 'Turn off button backlight',
              subtitle:
                  "Turn off main buttons' back-light during playback. (If back-light keeps turning on in spite of this option, uncheck this option and reboot device if necessary).",
              setting: PlayerSetting.turnOffBacklight),
          _toggle(ref,
              title: 'Loading circle animation',
              setting: PlayerSetting.loadingCircle),
          _toggle(ref,
              title: 'Software navigation buttons',
              subtitle:
                  'This device has software navigation buttons. (back, home, menu, etc.) Check this option if buttons are not hidden automatically.',
              setting: PlayerSetting.softwareNavButtons),
          _toggle(ref,
              title: 'Android 4.0 compatible mode',
              subtitle: 'Use this mode if you have problem with screen layout.',
              setting: PlayerSetting.android40Mode),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
