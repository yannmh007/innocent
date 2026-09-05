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
          const SettingsSectionHeader('Position'),
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
              title: 'Vertical position',
              subtitle: 'Distance from the top, as a percentage. Currently: $cur%',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Vertical Position',
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
            const optMap = <String, int>{
              'Left': 0,
              'Center': 1,
              'Right': 2,
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleHorizontalAlign);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () => const MapEntry('Center', 1))
                .key;
            return SettingsNavTile(
              title: 'Horizontal alignment',
              subtitle: 'Currently: $curLabel',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Horizontal Alignment',
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
          const SettingsSectionHeader('Spacing'),
          Builder(builder: (ctx) {
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.subtitleMarginX);
            return SettingsNavTile(
              title: 'Left/Right padding',
              subtitle: 'Pixels of horizontal margin. Currently: ${cur}px',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Left/Right Padding',
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
              title: 'Bottom margin',
              subtitle: 'Pixels of bottom margin. Currently: ${cur}px',
              onTap: () async {
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Bottom Margin',
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
          const SettingsSectionHeader('Background'),
          _toggle(ref,
              title: 'Show background',
              subtitle:
                  'Display semi-transparent background behind subtitle text.',
              setting: PlayerSetting.subLayoutShowBackground),
          Builder(builder: (ctx) {
            const colorMap = <String, String>{
              'Black (50% opacity)': '#80000000',
              'Black (75% opacity)': '#BF000000',
              'Dark gray': '#80303030',
              'None': '',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.subtitleBackgroundColor);
            final curLabel = colorMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        const MapEntry('Black (50% opacity)', '#80000000'))
                .key;
            return SettingsNavTile(
              title: 'Background color',
              subtitle: 'Active only when "Show background" is on. Currently: $curLabel',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Background Color',
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
