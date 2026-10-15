import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > Subtitle > Layout
/// Alignment, padding, background color settings.
///
/// Phase 41: toggles persist via [playerSettingsProvider].
class SubtitleLayoutScreen extends ConsumerWidget {
  const SubtitleLayoutScreen({super.key});

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
      appBar: AppBar(title: Text(AppStrings.of(context).subtitleLayoutTitle)),
      body: ListView(
        children: [
          SettingsSectionHeader(AppStrings.of(context).slyPosition),
          // Audit fix (standard high-quality): wire to libmpv
          // `sub-pos` via `IntSetting.subtitleVerticalPos`. 0 = top,
          // 100 = bottom. Live-apply path picks up the change on
          // the next openVideo (sub-pos can be set at runtime too;
          // future improvement).
          Builder(builder: (ctx) {
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleVerticalPos);
            return SettingsNavTile(
              title: AppStrings.of(context).slyVertical,
              subtitle: AppStrings.of(context).slyVerticalSub('$cur%'),
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: AppStrings.of(context).slyVertical,
                  currentValue: cur.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 100,
                  valueLabel: (v) => '${v.round()}%',
                );
                if (picked == null) return;
                await ref.read(extraSettingsProvider.notifier).setInt(
                    IntSetting.subtitleVerticalPos, picked.round());
              },
            );
          }),
          // Audit fix (standard high-quality): wire horizontal
          // alignment to libmpv `sub-align-x` via
          // IntSetting.subtitleHorizontalAlign. 0=left, 1=center,
          // 2=right. Applied live + on-open.
          Builder(builder: (ctx) {
            final optMap = <String, int>{
              AppStrings.of(context).slyLeft: 0,
              AppStrings.of(context).slyCenter: 1,
              AppStrings.of(context).slyRight: 2,
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleHorizontalAlign);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () => MapEntry(AppStrings.of(context).slyCenter, 1))
                .key;
            return SettingsNavTile(
              title: AppStrings.of(context).slyHorizontal,
              subtitle: AppStrings.of(context).slyCurrently(curLabel),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).slyHorizontal,
                  options: optMap.keys.toList(),
                  currentValue: curLabel,
                );
                if (picked == null) return;
                final v = optMap[picked];
                if (v == null) return;
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setInt(IntSetting.subtitleHorizontalAlign, v);
              },
            );
          }),
          SettingsSectionHeader(AppStrings.of(context).slySpacing),
          Builder(builder: (ctx) {
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleMarginX);
            return SettingsNavTile(
              title: AppStrings.of(context).slyPadX,
              subtitle: AppStrings.of(context).slyPadXSub('${cur}px'),
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: AppStrings.of(context).slyPadX,
                  currentValue: cur.toDouble(),
                  min: 0,
                  max: 200,
                  divisions: 40,
                  valueLabel: (v) => '${v.round()}px',
                );
                if (picked == null) return;
                await ref.read(extraSettingsProvider.notifier).setInt(
                    IntSetting.subtitleMarginX, picked.round());
              },
            );
          }),
          Builder(builder: (ctx) {
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleMarginY);
            return SettingsNavTile(
              title: AppStrings.of(context).slyPadY,
              subtitle: AppStrings.of(context).slyPadYSub('${cur}px'),
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: AppStrings.of(context).slyPadY,
                  currentValue: cur.toDouble(),
                  min: 0,
                  max: 200,
                  divisions: 40,
                  valueLabel: (v) => '${v.round()}px',
                );
                if (picked == null) return;
                await ref.read(extraSettingsProvider.notifier).setInt(
                    IntSetting.subtitleMarginY, picked.round());
              },
            );
          }),
          SettingsSectionHeader(AppStrings.of(context).slyBackground),
          _toggle(ref,
              title: AppStrings.of(context).slyShowBg,
              subtitle:
                  AppStrings.of(context).slyShowBgSub,
              setting: PlayerSetting.subLayoutShowBackground),
          Builder(builder: (ctx) {
            final colorMap = <String, String>{
              AppStrings.of(context).slyBlack50: '#80000000',
              AppStrings.of(context).slyBlack75: '#BF000000',
              AppStrings.of(context).slyDarkGray: '#80303030',
              AppStrings.of(context).slyNone: '',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.subtitleBackgroundColor);
            final curLabel = colorMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        MapEntry(AppStrings.of(context).slyBlack50, '#80000000'))
                .key;
            return SettingsNavTile(
              title: AppStrings.of(context).slyBgColor,
              subtitle: AppStrings.of(context).slyBgColorSub(curLabel),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).slyBgColor,
                  options: colorMap.keys.toList(),
                  currentValue: curLabel,
                );
                if (picked == null) return;
                final hex = colorMap[picked];
                if (hex == null) return;
                await ref.read(extraSettingsProvider.notifier).setStr(
                    StringSetting.subtitleBackgroundColor, hex);
              },
            );
          }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
