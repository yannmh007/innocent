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
          SettingsSectionHeader(AppStrings.of(context).spInterface),
          SettingsNavTile(
            title: AppStrings.of(context).styleTitle,
            onTap: () => _openSub(context, const PlayerStyleScreen()),
          ),
          SettingsNavTile(
            title: AppStrings.of(context).screenTitle,
            subtitle:
                AppStrings.of(context).spScreenSub,
            onTap: () =>
                _openSub(context, const PlayerScreenSettingsScreen()),
          ),
          SettingsNavTile(
            title: AppStrings.of(context).controlsTitle,
            subtitle:
                AppStrings.of(context).spControlsSub,
            onTap: () => _openSub(context, const PlayerControlsScreen()),
          ),
          SettingsNavTile(
            title: AppStrings.of(context).navigationTitle,
            subtitle:
                AppStrings.of(context).spNavigationSub,
            onTap: () => _openSub(context, const PlayerNavigationScreen()),
          ),
          _toggle(ref,
              title: AppStrings.of(context).spDoubleBack,
              subtitle: AppStrings.of(context).spDoubleBackSub,
              setting: PlayerSetting.doubleTapBack),
          _toggle(ref,
              title: AppStrings.of(context).spQuickZoom,
              subtitle:
                  AppStrings.of(context).spQuickZoomSub,
              setting: PlayerSetting.quickZoom),
          // Audit fix (A4): pin the player controls so they never
          // auto-hide. Useful for tutorial recordings or anyone who
          // wants the timestamp permanently in view.
          _toggle(ref,
              title: AppStrings.of(context).spPinControls,
              subtitle:
                  AppStrings.of(context).spPinControlsSub,
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
              title: AppStrings.of(context).spHideDelay,
              subtitle:
                  AppStrings.of(context).spHideDelaySub(AppStrings.of(context).secondsCount(current)),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).spHideDelay,
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
          SettingsSectionHeader(AppStrings.of(context).spPlayback),
          Builder(builder: (ctx) {
            // MX's `resume_last`: 'ask' (default), 'resume', 'startover'.
            final s = AppStrings.of(context);
            final labels = <String, String>{
              'ask': s.spResumeAsk,
              'resume': s.spResumeAlways,
              'startover': s.spResumeNever,
            };
            final current = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.resumeLast);
            final label = labels[current] ?? labels['ask']!;
            return SettingsNavTile(
              title: s.spResume,
              subtitle: s.spResumeSub(label),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.spResume,
                  options: labels.values.toList(),
                  currentValue: label,
                );
                if (picked == null) return;
                final next = labels.entries
                    .where((e) => e.value == picked)
                    .map((e) => e.key)
                    .firstOrNull;
                if (next == null) return;
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setStr(StringSetting.resumeLast, next);
              },
            );
          }),
          _toggle(ref,
              title: AppStrings.of(context).spResumeFirst,
              subtitle:
                  AppStrings.of(context).spResumeFirstSub,
              setting: PlayerSetting.resumeOnlyFirst),
          Builder(builder: (ctx) {
            // Phase 45 (audit): MX Player V3 stores default playback
            // speed as an integer percent 25..400 (default 100). We
            // display as a multiplier and persist as int.
            final pct = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.defaultPlaybackSpeed);
            return SettingsNavTile(
              title: AppStrings.of(context).spDefaultSpeed,
              subtitle: '${(pct / 100).toStringAsFixed(2)}x',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: AppStrings.of(context).spDefaultSpeed,
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
              title: AppStrings.of(context).spRemember,
              subtitle:
                  AppStrings.of(context).spRememberSub,
              setting: PlayerSetting.rememberSelections),
          _toggle(ref,
              title: AppStrings.of(context).spBackToList,
              subtitle: AppStrings.of(context).spBackToListSub,
              setting: PlayerSetting.backToList),
          _toggle(ref,
              title: AppStrings.of(context).spPreviewSeek,
              subtitle:
                  AppStrings.of(context).spPreviewSeekSub,
              setting: PlayerSetting.previewSeek),
          _toggle(ref,
              title: AppStrings.of(context).spPreviewSeekNet,
              subtitle: AppStrings.of(context).spPreviewSeekNetSub,
              setting: PlayerSetting.previewSeekNetwork),
          _toggle(ref,
              title: AppStrings.of(context).spFastSeek,
              subtitle:
                  AppStrings.of(context).spFastSeekSub,
              setting: PlayerSetting.fastSeeking),
          _toggle(ref,
              title: AppStrings.of(context).spPlayAlone,
              subtitle:
                  AppStrings.of(context).spPlayAloneSub,
              setting: PlayerSetting.playAlone),
          _toggle(ref,
              title: AppStrings.of(context).spMediaButtons,
              subtitle:
                  AppStrings.of(context).spMediaButtonsSub,
              setting: PlayerSetting.mediaButtons),
          // Phase 45 (audit refined, build 64): wire Next/Prev → FF/Rew
          // to PlayerSetting.customPopupFastForward (already exists
          // for the custom pop-up; we reuse it for the global media
          // button mapping policy — same semantic).
          _toggle(ref,
              title: AppStrings.of(context).spNextPrevFf,
              subtitle:
                  AppStrings.of(context).spNextPrevFfSub,
              setting: PlayerSetting.customPopupFastForward),
          _toggle(ref,
              title: AppStrings.of(context).spTogglePlay,
              subtitle:
                  AppStrings.of(context).spTogglePlaySub,
              setting: PlayerSetting.togglePlayback),
          _toggle(ref,
              title: AppStrings.of(context).spSmartPrev,
              subtitle:
                  AppStrings.of(context).spSmartPrevSub,
              setting: PlayerSetting.smartPrevious),
          _toggle(ref,
              title: AppStrings.of(context).spSuppressError,
              subtitle:
                  AppStrings.of(context).spSuppressErrorSub,
              setting: PlayerSetting.suppressError),
          _toggle(ref,
              title: AppStrings.of(context).spCustomPip,
              subtitle: AppStrings.of(context).spCustomPipSub,
              setting: PlayerSetting.useCustomPip),
          SettingsSectionHeader(AppStrings.of(context).spBackground),
          Builder(builder: (ctx) {
            // MX's `sticky_video`: 'stop', 'background', 'pip' (default).
            final s = AppStrings.of(context);
            final labels = <String, String>{
              'pip': s.spBgPip,
              'background': s.spBgPlay,
              'stop': s.spBgStop,
            };
            final current = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.stickyVideo);
            final label = labels[current] ?? labels['pip']!;
            return SettingsNavTile(
              title: s.spBgMode,
              subtitle: s.spBgModeSub(label),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.spBgMode,
                  options: labels.values.toList(),
                  currentValue: label,
                );
                if (picked == null) return;
                final next = labels.entries
                    .where((e) => e.value == picked)
                    .map((e) => e.key)
                    .firstOrNull;
                if (next == null) return;
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setStr(StringSetting.stickyVideo, next);
              },
            );
          }),
          _toggle(ref,
              title: AppStrings.of(context).spBgAudio,
              subtitle: AppStrings.of(context).spBgAudioSub,
              setting: PlayerSetting.bgPlayAudio),
          SettingsSectionHeader(AppStrings.of(context).spMisc),
          _toggle(ref,
              title: AppStrings.of(context).spLimitResize,
              subtitle:
                  AppStrings.of(context).spLimitResizeSub,
              setting: PlayerSetting.limitResize),
          _toggle(ref,
              title: AppStrings.of(context).spLoadingCircle,
              setting: PlayerSetting.loadingCircle),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
