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
              title: AppStrings.of(context).ssFolder,
              subtitle: folder.isEmpty
                  ? AppStrings.of(context).ssFolderSame
                  : folder,
              onTap: () async {
                final picked = await showSettingsTextDialog(
                  context: context,
                  title: AppStrings.of(context).ssFolder,
                  currentValue: folder,
                  hintText: AppStrings.of(context).ssFolderHint,
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
            final charsetMap = <String, String>{
              AppStrings.of(context).ssAutoDetect: '',
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
                  orElse: () => MapEntry(AppStrings.of(context).ssAutoDetect, ''),
                )
                .key;
            return SettingsNavTile(
              title: AppStrings.of(context).ssEncoding,
              subtitle:
                  AppStrings.of(context).ssEncodingSub(currentLabel),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).ssEncoding,
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
            final langMap = <String, String>{
              AppStrings.of(context).langNone: '',
              AppStrings.of(context).langEnglish: 'eng',
              AppStrings.of(context).langMyanmar: 'mya',
              AppStrings.of(context).langJapanese: 'jpn',
              AppStrings.of(context).langKorean: 'kor',
              AppStrings.of(context).langChinese: 'chi',
              AppStrings.of(context).langThai: 'tha',
              AppStrings.of(context).langVietnamese: 'vie',
            };
            final current = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.subtitleLanguage);
            final currentLabel = langMap.entries
                .firstWhere(
                  (e) => e.value == current,
                  orElse: () => MapEntry(AppStrings.of(context).langNone, ''),
                )
                .key;
            return SettingsNavTile(
              title: AppStrings.of(context).ssLanguage,
              subtitle:
                  AppStrings.of(context).ssLanguageSub(currentLabel),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).ssLanguage,
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
              title: AppStrings.of(context).ssSync,
              subtitle:
                  AppStrings.of(context).ssSyncSub('${ms >= 0 ? "+" : ""}${ms}ms'),
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: AppStrings.of(context).ssSync,
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
              title: AppStrings.of(context).ssHwSync,
              subtitle:
                  AppStrings.of(context).ssHwSyncSub('${hwSec >= 0 ? "+" : ""}${hwSec}s'),
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: AppStrings.of(context).ssHwSync,
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
          SettingsSectionHeader(AppStrings.of(context).ssAppearance),
          SettingsNavTile(
            title: AppStrings.of(context).ssText,
            subtitle:
                AppStrings.of(context).ssTextSub,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SubtitleTextScreen()),
            ),
          ),
          SettingsNavTile(
            title: AppStrings.of(context).ssLayout,
            subtitle:
                AppStrings.of(context).ssLayoutSub,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SubtitleLayoutScreen()),
            ),
          ),
          SettingsSectionHeader(AppStrings.of(context).ssProcessing),
          _toggle(ref,
              title: AppStrings.of(context).ssItalic,
              subtitle:
                  AppStrings.of(context).ssItalicSub,
              setting: PlayerSetting.subtitleItalicEffect),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
