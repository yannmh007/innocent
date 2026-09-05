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
          _toggle(ref,
              title: 'Audio player',
              subtitle: 'Use as audio player.',
              setting: PlayerSetting.audioAsPlayer),
          // Phase 45 (audit refined, build 63): wire Audio output to
          // StringSetting.audioDevice (was visible-only list dialog).
          // Persisted so subsequent plays respect the user's choice.
          Builder(builder: (ctx) {
            const optMap = <String, String>{
              'Auto (follow system)': 'auto',
              'Speaker': 'speaker',
              'Headphones': 'headphone',
              'Bluetooth': 'bluetooth',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.audioDevice);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        const MapEntry('Auto (follow system)', 'auto'))
                .key;
            return SettingsNavTile(
              title: 'Audio output',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Audio Output',
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
              title: 'Volume boost',
              subtitle:
                  'Audio volume can be boosted up to 200% if you use HW+ or SW decoder.',
              setting: PlayerSetting.audioVolumeBoost),
          // Audit fix (Phase 4 #15): loudness normalization toggle.
          _toggle(ref,
              title: 'Loudness normalization',
              subtitle:
                  'Even out loud and quiet scenes/songs so you don\'t need to ride the volume — similar to Spotify\'s loudness normalization. Best-effort, depends on libmpv codec support.',
              setting: PlayerSetting.loudnessNormalization),
          _toggle(ref,
              title: 'System volume',
              subtitle:
                  'Synchronize sound volume with the system media volume.',
              setting: PlayerSetting.audioSystemVolume),
          _toggle(ref,
              title: 'System volume panel',
              subtitle:
                  'Show system volume panel while changing volume with the headset plugged in.',
              setting: PlayerSetting.audioSystemVolumePanel),
          _toggle(ref,
              title: 'Pause on headset disconnected',
              subtitle:
                  'Pause playback when wired/Bluetooth headset disconnected from the device.',
              setting: PlayerSetting.audioPauseOnHeadsetDisconnect),
          _toggle(ref,
              title: 'Fade on start',
              setting: PlayerSetting.audioFadeOnStart),
          _toggle(ref,
              title: 'Fade on seek',
              setting: PlayerSetting.audioFadeOnSeek),
          // Phase 45 (audit refined, build 63): MX Player V3
          // `audio_effects_enabled` master toggle + Dolby/DTS
          // passthrough toggle.
          _toggle(ref,
              title: 'Audio effects',
              subtitle:
                  'Enable the Equalizer + Bass Boost + Virtualizer + Reverb pipeline.',
              setting: PlayerSetting.audioEffectsEnabled),
          _toggle(ref,
              title: 'Prefer audio passthrough',
              subtitle:
                  'Pass Dolby/DTS bitstream untouched to an AV receiver. Disable if you hear distortion through phone speakers.',
              setting: PlayerSetting.preferAudioPassthrough),
          // Phase 45 (audit): MX Player V3 `audio_language` is an ISO code
          // ('' = no preference). We map common languages to their ISO 639
          // codes for the picker UI but persist as the raw code so libmpv
          // can use them directly.
          Builder(builder: (ctx) {
            const langMap = <String, String>{
              'None': '',
              'English': 'eng',
              'Japanese': 'jpn',
              'Korean': 'kor',
              'Chinese': 'chi',
              'Myanmar': 'mya',
              'Thai': 'tha',
              'Hindi': 'hin',
            };
            final current = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.audioLanguage);
            final currentLabel = langMap.entries
                .firstWhere(
                  (e) => e.value == current,
                  orElse: () => const MapEntry('None', ''),
                )
                .key;
            return SettingsNavTile(
              title: 'Preferred audio language',
              subtitle:
                  'Language of the audio track you want to use. Currently: $currentLabel',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Preferred Audio Language',
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
              title: 'Audio delay',
              subtitle:
                  'Adjust audio delay (ms). Currently: ${ms >= 0 ? "+" : ""}${ms}ms',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Audio Delay',
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
          Builder(builder: (ctx) {
            final ms = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.bluetoothAudioDelay);
            return SettingsNavTile(
              title: 'Bluetooth audio delay',
              subtitle:
                  'Extra delay applied when audio routes through Bluetooth. Currently: ${ms >= 0 ? "+" : ""}${ms}ms',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Bluetooth Audio Delay',
                  currentValue: ms / 1000.0,
                  min: -2.0,
                  max: 2.0,
                  divisions: 40,
                  valueLabel: (v) =>
                      '${v >= 0 ? "+" : ""}${(v * 1000).round()}ms',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setInt(IntSetting.bluetoothAudioDelay,
                          (picked * 1000).round());
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
