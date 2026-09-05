import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > Player > Screen
/// Orientation, Full Screen, Brightness, etc.
///
/// Phase 41: toggles persist via [playerSettingsProvider].
class PlayerScreenSettingsScreen extends ConsumerWidget {
  const PlayerScreenSettingsScreen({super.key});

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
      appBar: AppBar(title: Text(AppStrings.of(context).screenTitle)),
      body: ListView(
        children: [
          const SettingsSectionHeader('Orientation'),
          // Audit fix (standard high-quality): wire default orientation
          // to StringSetting.defaultPlayerOrientation. 'system' lets
          // the existing `screenAutoRotation` toggle and device
          // rotation-lock take over (no override). Specific modes
          // pin the player regardless of device lock.
          Builder(builder: (ctx) {
            const optMap = <String, String>{
              'Follow system': 'system',
              'Landscape': 'landscape',
              'Landscape (reverse)': 'landscapeReverse',
              'Portrait': 'portrait',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.defaultPlayerOrientation);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        const MapEntry('Follow system', 'system'))
                .key;
            return SettingsNavTile(
              title: 'Default orientation',
              subtitle:
                  'Pin player orientation. "Follow system" respects Auto rotation toggle below. Currently: $curLabel',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Default Orientation',
                  options: optMap.keys.toList(),
                  currentValue: curLabel,
                );
                if (picked == null) return;
                final v = optMap[picked];
                if (v == null) return;
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setStr(StringSetting.defaultPlayerOrientation, v);
              },
            );
          }),
          _toggle(ref,
              title: 'Auto rotation',
              subtitle:
                  'Automatically rotate screen based on device orientation.',
              setting: PlayerSetting.screenAutoRotation),
          const SettingsSectionHeader('Display'),
          _toggle(ref,
              title: 'Full screen',
              subtitle:
                  'Hide system status bar and navigation bar during playback.',
              setting: PlayerSetting.screenFullScreen),
          _toggle(ref,
              title: 'Keep screen on',
              subtitle: 'Prevent screen from turning off during playback.',
              setting: PlayerSetting.screenKeepOn),
          const SettingsSectionHeader('Brightness'),
          _toggle(ref,
              title: 'Auto brightness',
              subtitle: 'Use system brightness setting.',
              setting: PlayerSetting.screenAutoBrightness),
          // Audit fix (standard high-quality): wire Default brightness
          // to `IntSetting.defaultBrightnessPct`. Value -1 = "follow
          // system" (we don't override). 0..100 = explicit percentage
          // applied on first open of a file that has no per-URI
          // brightness saved.
          Builder(builder: (ctx) {
            final cur = ref
                .watch(extraSettingsProvider)
                .getInt(IntSetting.defaultBrightnessPct);
            final label = cur < 0 ? 'Follow system' : '$cur%';
            return SettingsNavTile(
              title: 'Default brightness',
              subtitle: 'Default brightness for new videos (overridden per-video). Currently: $label',
              onTap: () async {
                // -1 represents 'follow system'; slider is 0..100.
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: 'Default Brightness (-1% = follow system)',
                  currentValue: cur < 0 ? -1.0 : cur.toDouble(),
                  min: -1,
                  max: 100,
                  divisions: 101,
                  valueLabel: (v) =>
                      v < 0 ? 'Follow system' : '${v.round()}%',
                );
                if (picked == null) return;
                await ref.read(extraSettingsProvider.notifier).setInt(
                    IntSetting.defaultBrightnessPct, picked.round());
              },
            );
          }),
          const SettingsSectionHeader('Notch / Cutout'),
          _toggle(ref,
              title: 'Dim notch area',
              subtitle: 'Dim the notch area to reduce visual distraction.',
              setting: PlayerSetting.screenDimNotch),
          _toggle(ref,
              title: 'Use cutout area',
              subtitle: 'Extend video to the display cutout area.',
              setting: PlayerSetting.screenUseCutout),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
