import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';
import 'subtitle_layout_screen.dart';
import 'subtitle_text_screen.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > Subtitle — full MX Player parity (UI PDF page 17).
/// Sections: default, Appearance, Text processing.
///
/// Phase 41: toggles persist via [playerSettingsProvider].
class SettingsSubtitleScreen extends ConsumerWidget {
  const SettingsSubtitleScreen({super.key});

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
      appBar: AppBar(title: Text(AppStrings.of(context).settingsSubtitle)),
      body: ListView(
        children: [
          // Phase 45 (audit): Subtitle Folder backed by ExtraSettings.
          Builder(builder: (ctx) {
            final folder = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.subtitleFolder);
            return SettingsNavTile(
              title: 'Subtitle Folder',
              subtitle: folder.isEmpty
                  ? 'Only the same folder as the video'
                  : folder,
              onTap: () async {
                final picked = await showSettingsTextDialog(
                  context: context,
                  title: 'Subtitle Folder',
                  currentValue: folder,
                  hintText: 'e.g. /storage/emulated/0/Subtitles',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.subtitleFolder, picked.trim());
                }
              },
            );
          }),
          // Phase 45 (audit): Character encoding. Maps display labels to
          // libmpv `sub-codepage` values. Empty string = auto-detect.
          Builder(builder: (ctx) {
            const charsetMap = <String, String>{
              'Auto detect': '',
              'UTF-8': 'UTF-8',
              'UTF-16': 'UTF-16',
              'ASCII': 'ASCII',
              'ISO-8859-1': 'ISO-8859-1',
              'Windows-1252': 'CP1252',
              'EUC-KR': 'EUC-KR',
              'Shift_JIS': 'SHIFT_JIS',
              'Big5': 'BIG5',
              'GB18030': 'GB18030',
            };
            final current = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.subtitleCharset);
            final currentLabel = charsetMap.entries
                .firstWhere(
                  (e) => e.value == current,
                  orElse: () => const MapEntry('Auto detect', ''),
                )
                .key;
            return SettingsNavTile(
              title: 'Character encoding',
              subtitle:
                  'Select character encoding of your subtitle file. Currently: $currentLabel',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Character Encoding',
                  options: charsetMap.keys.toList(),
                  currentValue: currentLabel,
                );
                if (picked != null && charsetMap.containsKey(picked)) {
                  await ref.read(extraSettingsProvider.notifier).setStr(
                      StringSetting.subtitleCharset, charsetMap[picked]!);
                }
              },
            );
          }),
          // Phase 45 (audit): Preferred subtitle language (ISO 639 code).
          Builder(builder: (ctx) {
            const langMap = <String, String>{
              'None': '',
              'English': 'eng',
              'Myanmar': 'mya',
              'Japanese': 'jpn',
              'Korean': 'kor',
              'Chinese': 'chi',
              'Thai': 'tha',
              'Vietnamese': 'vie',
            };
            final current = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.subtitleLanguage);
            final currentLabel = langMap.entries
                .firstWhere(
                  (e) => e.value == current,
                  orElse: () => const MapEntry('None', ''),
                )
                .key;
            return SettingsNavTile(
              title: 'Preferred subtitle language',
              subtitle:
                  'Language of the subtitle track you want to use. Currently: $currentLabel',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Preferred Subtitle Language',
                  options: langMap.keys.toList(),
                  currentValue: currentLabel,
                );
                if (picked != null && langMap.containsKey(picked)) {
                  await ref.read(extraSettingsProvider.notifier).setStr(
                      StringSetting.subtitleLanguage, langMap[picked]!);
                }
              },
            );
          }),
          // Phase 45 (audit): Default subtitle sync (libmpv sub-delay).
          Builder(builder: (ctx) {
            final ms = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleDefaultSync);
            return SettingsNavTile(
              title: 'Default sync',
              subtitle:
                  'Default time adjustment for subtitle synchronization. Currently: ${ms >= 0 ? "+" : ""}${ms}ms',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Default Sync',
                  currentValue: ms / 1000.0,
                  min: -10.0,
                  max: 10.0,
                  divisions: 200,
                  valueLabel: (v) =>
                      '${v >= 0 ? "+" : ""}${(v * 1000).round()}ms',
                );
                if (picked != null) {
                  await ref.read(extraSettingsProvider.notifier).setInt(
                      IntSetting.subtitleDefaultSync,
                      (picked * 1000).round());
                }
              },
            );
          }),
          // Phase 45 (audit refined, build 63): wire "Sync for HW
          // decoder" to IntSetting.calibrateHwPlayPosition. Range
          // matches MX Player V3 (-10..+10 seconds). Stacked with the
          // primary subtitle_default_sync on every play.
          Builder(builder: (ctx) {
            final hwSec = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.calibrateHwPlayPosition);
            return SettingsNavTile(
              title: 'Sync for HW decoder',
              subtitle:
                  'Compensate for HW decoder presentation latency. Currently ${hwSec >= 0 ? "+" : ""}${hwSec}s',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Sync for HW Decoder',
                  currentValue: hwSec.toDouble(),
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
          // Phase 45 (audit refined, build 63): MX Player V3 has
          // `subtitle_show_hw` (force subtitle visibility during HW
          // decode — some chipsets need this) and `subtitle_hw_accel`
          // (use the GPU for subtitle compositing).
          _toggle(ref,
              title: 'Show subtitle during HW decode',
              subtitle:
                  'Force subtitles to render even with HW decoder. Helps on some Mediatek/Allwinner chipsets that drop subtitle frames during HW decode.',
              setting: PlayerSetting.subtitleShowHw),
          _toggle(ref,
              title: 'Hardware-accelerated subtitle rendering',
              subtitle:
                  'Use the GPU to composite subtitle bitmaps. Reduces CPU load. Turn off if subtitles flicker.',
              setting: PlayerSetting.subtitleHwAccel),
          const SettingsSectionHeader('Appearance'),
          SettingsNavTile(
            title: 'Text',
            subtitle:
                'Subtitle text settings: font, size, color, border, etc.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SubtitleTextScreen()),
            ),
          ),
          SettingsNavTile(
            title: 'Layout',
            subtitle:
                'Subtitle layout settings: alignment, padding, background color.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SubtitleLayoutScreen()),
            ),
          ),
          // Phase 45 (audit): Font Folder for custom .ttf/.otf subtitle
          // fonts. MX Player's `typeface_dir` setting.
          Builder(builder: (ctx) {
            final folder = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.typefaceDir);
            return SettingsNavTile(
              title: 'Font Folder',
              subtitle: folder.isEmpty
                  ? 'Use system fonts'
                  : folder,
              onTap: () async {
                final picked = await showSettingsTextDialog(
                  context: context,
                  title: 'Font Folder',
                  subtitle: 'Folder containing .ttf/.otf files. Leave blank to use system fonts.',
                  currentValue: folder,
                  hintText: 'e.g. /storage/emulated/0/Fonts',
                );
                if (picked != null) {
                  await ref
                      .read(extraSettingsProvider.notifier)
                      .setStr(StringSetting.typefaceDir, picked.trim());
                }
              },
            );
          }),
          const SettingsSectionHeader('Text processing'),
          _toggle(ref,
              title: 'Italic effect',
              subtitle:
                  "Sentences that start with '/' (forward slash) will be displayed in italics.",
              setting: PlayerSetting.subtitleItalicEffect),
          _toggle(ref,
              title: 'Force LTR direction',
              subtitle:
                  'Force LTR (Left to Right) direction for RTL (Right to Left) subtitles.',
              setting: PlayerSetting.subtitleForceLtr),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
