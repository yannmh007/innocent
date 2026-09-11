import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > Decoder — full MX Player parity (UI PDF page 16).
/// Sections: Hardware decoder, Software decoder, General.
///
/// Phase 41: toggles persist via [playerSettingsProvider].
class SettingsDecoderScreen extends ConsumerWidget {
  const SettingsDecoderScreen({super.key});

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
      appBar: AppBar(title: Text(AppStrings.of(context).settingsDecoder)),
      body: ListView(
        children: [
          const SettingsSectionHeader('Hardware decoder'),
          // Phase 45 (audit refined, build 63): MX Player V3's
          // `omxdecoder.2` selector — 4-mode HW decoder strategy.
          // Different from per-stream decHwLocal/decHwNetwork toggles
          // (which are added below). This is the OVERALL "when to
          // attempt HW decode" policy.
          Builder(builder: (ctx) {
            const optMap = <String, String>{
              'Auto (default)': 'auto',
              'Never use HW decoder': 'never',
              'Local files only': 'localOnly',
              'Always try HW first': 'everywhere',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.omxDecoderMode);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () => const MapEntry('Auto (default)', 'auto'))
                .key;
            return SettingsNavTile(
              title: 'HW decoder strategy',
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'HW Decoder Strategy',
                  options: optMap.keys.toList(),
                  currentValue: curLabel,
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.omxDecoderMode,
                          optMap[picked] ?? 'auto');
                }
              },
            );
          }),
          _toggle(ref,
              title: 'HW+ decoder (local)',
              subtitle:
                  'Set HW+ decoder as the default hardware decoder for local files.',
              setting: PlayerSetting.decHwLocal),
          _toggle(ref,
              title: 'HW+ decoder (network)',
              subtitle:
                  'Set HW+ decoder as the default hardware decoder for network play.',
              setting: PlayerSetting.decHwNetwork),
          _toggle(ref,
              title: 'Try HW decoder',
              subtitle: 'Try HW decoder if HW+ decoder fails.',
              setting: PlayerSetting.decTryHw),
          _toggle(ref,
              title: 'Try HW+ decoder',
              subtitle: 'Try HW+ decoder if HW decoder fails.',
              setting: PlayerSetting.decTryHwPlus),
          // Phase 45 (audit refined, build 64): wire HW+ video codecs
          // to StringSetting.hwPlusVideoCodecs (pipe-separated list).
          Builder(builder: (ctx) {
            const allOpts = [
              'H.264/AVC',
              'H.265/HEVC',
              'MPEG-4',
              'VP8',
              'VP9',
              'AV1',
              'MPEG-2'
            ];
            const defaults = ['H.264/AVC', 'H.265/HEVC'];
            final raw = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.hwPlusVideoCodecs);
            final selected =
                raw.isEmpty ? defaults : raw.split('|');
            return SettingsNavTile(
              title: 'HW+ video codecs',
              subtitle: '${selected.length} codecs enabled',
              onTap: () async {
                final picked = await showSettingsMultiSelectDialog(
                  context: context,
                  title: 'HW+ Video Codecs',
                  options: allOpts,
                  selectedValues: selected,
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.hwPlusVideoCodecs,
                          picked.join('|'));
                }
              },
            );
          }),
          // Phase 45 (audit refined, build 64): wire HW+ audio codecs.
          Builder(builder: (ctx) {
            const allOpts = [
              'AAC',
              'MP3',
              'AC3',
              'DTS',
              'FLAC',
              'Vorbis',
              'Opus',
              'PCM'
            ];
            const defaults = ['AAC', 'MP3'];
            final raw = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.hwPlusAudioCodecs);
            final selected =
                raw.isEmpty ? defaults : raw.split('|');
            return SettingsNavTile(
              title: 'HW+ audio codecs',
              subtitle: '${selected.length} codecs enabled',
              onTap: () async {
                final picked = await showSettingsMultiSelectDialog(
                  context: context,
                  title: 'HW+ Audio Codecs',
                  options: allOpts,
                  selectedValues: selected,
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.hwPlusAudioCodecs,
                          picked.join('|'));
                }
              },
            );
          }),
          _toggle(ref,
              title: 'HW+ audio on SW video',
              subtitle:
                  'Use HW+ audio decoder if SW audio decoder fails in SW decoding mode.',
              setting: PlayerSetting.decHwAudioOnSwVideo),
          _toggle(ref,
              title: 'Correct aspect ratio',
              subtitle:
                  'Correct aspect ratio of HW decoded videos. Use this option if HW decoder ignores aspect ratio.',
              setting: PlayerSetting.decCorrectAspect),
          // Phase 45 (audit refined, build 64): wire Calibrate playback
          // position to IntSetting.calibrateHwPlayPosition. Already
          // applied in openVideo() as the HW decoder subtitle sync
          // offset; the slider also adjusts perceived playback position.
          Builder(builder: (ctx) {
            final sec = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.calibrateHwPlayPosition);
            return SettingsNavTile(
              title: 'Calibrate playback position',
              subtitle:
                  'Currently ${sec >= 0 ? "+" : ""}${sec}s. Adjust if HW decoder reports incorrect position.',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Calibrate Playback Position',
                  currentValue: sec.toDouble(),
                  min: -10,
                  max: 10,
                  divisions: 20,
                  valueLabel: (v) =>
                      '${v >= 0 ? "+" : ""}${v.round()}s',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setInt(IntSetting.calibrateHwPlayPosition,
                          picked.round());
                }
              },
            );
          }),
          _toggle(ref,
              title: 'HW audio track selectable',
              subtitle:
                  'Turn it off only if HW decoder crashes immediately after changing audio track or playing videos using an unsupported audio codec. If this option is turned off, custom audio codecs will not be used automatically with HW decoder.',
              setting: PlayerSetting.decHwAudioTrackSelectable),
          const SettingsSectionHeader('Software decoder'),
          _toggle(ref,
              title: 'SW decoder (local)',
              subtitle: 'Use SW decoder for local files stored on the device.',
              setting: PlayerSetting.decSwLocal),
          _toggle(ref,
              title: 'SW decoder (network)',
              subtitle:
                  'Use SW decoder for network play from remote sources via HTTP, FTP, RTSP, MMS and more.',
              setting: PlayerSetting.decSwNetwork),
          _toggle(ref,
              title: 'SW audio',
              subtitle: 'Use SW audio decoder instead of HW audio decoder.',
              setting: PlayerSetting.decSwAudio),
          _toggle(ref,
              title: 'SW audio (local)',
              subtitle:
                  'Use SW audio decoder for playing local files stored on the device.',
              setting: PlayerSetting.decSwAudioLocal),
          _toggle(ref,
              title: 'SW audio (network)',
              subtitle:
                  'Use SW audio decoder for playing remote network sources.',
              setting: PlayerSetting.decSwAudioNetwork),
          // Audit fix (standard high-quality): wire CPU Core Limit
          // to `IntSetting.videoDecoderThreads` which the player
          // service feeds into libmpv's `vd-lavc-threads` on open.
          // 0 = libmpv auto. Useful on thermally constrained
          // devices to prevent decoder thrashing the CPU.
          Builder(builder: (ctx) {
            const optMap = <String, int>{
              'Auto (recommended)': 0,
              '1': 1,
              '2': 2,
              '4': 4,
              '8': 8,
              '16': 16,
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.videoDecoderThreads);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        const MapEntry('Auto (recommended)', 0))
                .key;
            return SettingsNavTile(
              title: 'CPU Core Limit',
              subtitle: 'Max CPU threads for SW video decoding (libmpv vd-lavc-threads). Currently: $curLabel',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'CPU Core Limit',
                  options: optMap.keys.toList(),
                  currentValue: curLabel,
                );
                if (picked == null) return;
                final n = optMap[picked];
                if (n == null) return;
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setInt(IntSetting.videoDecoderThreads, n);
              },
            );
          }),
          // Audit fix (standard high-quality): Color format on
          // libmpv-backed players is auto-selected — there's no
          // user-controllable knob equivalent to MX Player's V3
          // legacy "RGB 565 / RGB 8888 / YUV" picker. Rather than
          // pretend, surface an informational dialog explaining
          // why the choice doesn't apply.
          SettingsNavTile(
            title: 'Color format',
            subtitle:
                'Auto-selected by libmpv based on GPU + display. Tap for details.',
            onTap: () => showDialog<void>(
              context: context,
              builder: (dctx) => AlertDialog(
                backgroundColor: AppColors.darkSurface,
                title: Text(AppStrings.of(context).colorFormat,
                  style: const TextStyle(color: Colors.white),
                ),
                content: const Text(
                  'On this player, the video output format (RGB 565 / 8888 / YUV) '
                  "is selected automatically by libmpv to match your GPU and "
                  "display's preferred mode. Manual override is not exposed "
                  'and rarely useful — modern GPUs handle YUV natively and '
                  'misconfiguration can cause green-screen artefacts.\n\n'
                  'If you suspect a colour issue, try switching the decoder '
                  '(HW / HW+ / SW) on the player screen first.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dctx).pop(),
                    child: Text(AppStrings.of(context).ok,
                        style: const TextStyle(color: AppColors.accentBlue)),
                  ),
                ],
              ),
            ),
          ),
          _toggle(ref,
              title: 'Use speedup tricks',
              setting: PlayerSetting.decSpeedupTricks),
          const SettingsSectionHeader('General'),
          _toggle(ref,
              title: 'Deinterlace',
              subtitle:
                  'Deinterlace by default. Currently deinterlacing works only with SW decoder.',
              setting: PlayerSetting.decDeinterlace),
          _toggle(ref,
              title: 'Custom codec',
              subtitle: 'Use ARMv8 NEON type custom codec.',
              setting: PlayerSetting.decCustomCodec),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
