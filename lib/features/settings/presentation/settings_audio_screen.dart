import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > Audio — full MX Player parity (UI PDF page 17).
/// Phase 41: all toggles persist via [playerSettingsProvider].
class SettingsAudioScreen extends ConsumerWidget {
  const SettingsAudioScreen({super.key});

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
      appBar: AppBar(title: Text(AppStrings.of(context).settingsAudio)),
      body: ListView(
        children: [
          // Phase 45 (audit refined, build 63): wire Audio output to
          // StringSetting.audioDevice (was visible-only list dialog).
          // Persisted so subsequent plays respect the user's choice.
          Builder(builder: (ctx) {
            final optMap = <String, String>{
              AppStrings.of(context).saAuto: 'auto',
              AppStrings.of(context).saSpeaker: 'speaker',
              AppStrings.of(context).saHeadphones: 'headphone',
              AppStrings.of(context).saBluetooth: 'bluetooth',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.audioDevice);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        MapEntry(AppStrings.of(context).saAuto, 'auto'))
                .key;
            return SettingsNavTile(
              title: AppStrings.of(context).saOutput,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).saOutput,
                  options: optMap.keys.toList(),
                  currentValue: curLabel,
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.audioDevice,
                          optMap[picked] ?? 'auto');
                }
              },
            );
          }),
          _toggle(ref,
              title: AppStrings.of(context).saBoost,
              subtitle:
                  AppStrings.of(context).saBoostSub,
              setting: PlayerSetting.audioVolumeBoost),
          // Audit fix (Phase 4 #15): loudness normalization toggle.
          _toggle(ref,
              title: AppStrings.of(context).saLoudness,
              subtitle:
                  AppStrings.of(context).saLoudnessSub,
              setting: PlayerSetting.loudnessNormalization),
          _toggle(ref,
              title: AppStrings.of(context).saSystemVolume,
              subtitle:
                  AppStrings.of(context).saSystemVolumeSub,
              setting: PlayerSetting.audioSystemVolume),
          _toggle(ref,
              title: AppStrings.of(context).saPauseHeadset,
              subtitle:
                  AppStrings.of(context).saPauseHeadsetSub,
              setting: PlayerSetting.audioPauseOnHeadsetDisconnect),
          _toggle(ref,
              title: AppStrings.of(context).saFadeStart,
              setting: PlayerSetting.audioFadeOnStart),
          _toggle(ref,
              title: AppStrings.of(context).saFadeSeek,
              setting: PlayerSetting.audioFadeOnSeek),
          // Phase 45 (audit refined, build 63): MX Player V3
          // `audio_effects_enabled` master toggle + Dolby/DTS
          // passthrough toggle.
          _toggle(ref,
              title: AppStrings.of(context).saEffects,
              subtitle:
                  AppStrings.of(context).saEffectsSub,
              setting: PlayerSetting.audioEffectsEnabled),
          _toggle(ref,
              title: AppStrings.of(context).saPassthrough,
              subtitle:
                  AppStrings.of(context).saPassthroughSub,
              setting: PlayerSetting.preferAudioPassthrough),
          // Phase 45 (audit): MX Player V3 `audio_language` is an ISO code
          // ('' = no preference). We map common languages to their ISO 639
          // codes for the picker UI but persist as the raw code so libmpv
          // can use them directly.
          Builder(builder: (ctx) {
            final langMap = <String, String>{
              AppStrings.of(context).langNone: '',
              AppStrings.of(context).langEnglish: 'eng',
              AppStrings.of(context).langJapanese: 'jpn',
              AppStrings.of(context).langKorean: 'kor',
              AppStrings.of(context).langChinese: 'chi',
              AppStrings.of(context).langMyanmar: 'mya',
              AppStrings.of(context).langThai: 'tha',
              AppStrings.of(context).langHindi: 'hin',
            };
            final current = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.audioLanguage);
            final currentLabel = langMap.entries
                .firstWhere(
                  (e) => e.value == current,
                  orElse: () => MapEntry(AppStrings.of(context).langNone, ''),
                )
                .key;
            return SettingsNavTile(
              title: AppStrings.of(context).saLanguage,
              subtitle:
                  AppStrings.of(context).saLanguageSub(currentLabel),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).saLanguage,
                  options: langMap.keys.toList(),
                  currentValue: currentLabel,
                );
                if (picked != null && langMap.containsKey(picked)) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.audioLanguage, langMap[picked]!);
                }
              },
            );
          }),
          Builder(builder: (ctx) {
            final ms = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.audioDelay);
            return SettingsNavTile(
              title: AppStrings.of(context).saDelay,
              subtitle:
                  AppStrings.of(context).saDelaySub('${ms >= 0 ? "+" : ""}${ms}ms'),
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: AppStrings.of(context).saDelay,
                  currentValue: ms / 1000.0,
                  min: -2.0,
                  max: 2.0,
                  divisions: 80,
                  valueLabel: (v) =>
                      '${v >= 0 ? "+" : ""}${(v * 1000).round()}ms',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setInt(IntSetting.audioDelay, (picked * 1000).round());
                }
              },
            );
          }),
          // Note: "Prefer audio passthrough" already exposed earlier in
          // this screen as a wired toggle bound to
          // PlayerSetting.preferAudioPassthrough — duplicate visible-
          // only tile removed here.
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
