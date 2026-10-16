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
          SettingsSectionHeader(AppStrings.of(context).pssOrientation),
          // Audit fix (standard high-quality): wire default orientation
          // to StringSetting.defaultPlayerOrientation. 'system' lets
          // the existing `screenAutoRotation` toggle and device
          // rotation-lock take over (no override). Specific modes
          // pin the player regardless of device lock.
          Builder(builder: (ctx) {
            final optMap = <String, String>{
              AppStrings.of(context).pssFollowSystem: 'system',
              AppStrings.of(context).pssLandscape: 'landscape',
              AppStrings.of(context).pssLandscapeReverse: 'landscapeReverse',
              AppStrings.of(context).pssPortrait: 'portrait',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.defaultPlayerOrientation);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        MapEntry(AppStrings.of(context).pssFollowSystem, 'system'))
                .key;
            return SettingsNavTile(
              title: AppStrings.of(context).pssDefaultOrientation,
              subtitle:
                  AppStrings.of(context).pssDefaultOrientationSub(curLabel),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).pssDefaultOrientation,
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
              title: AppStrings.of(context).pssAutoRotation,
              subtitle:
                  AppStrings.of(context).pssAutoRotationSub,
              setting: PlayerSetting.screenAutoRotation),
          SettingsSectionHeader(AppStrings.of(context).pssDisplay),
          _toggle(ref,
              title: AppStrings.of(context).pssFullScreen,
              subtitle:
                  AppStrings.of(context).pssFullScreenSub,
              setting: PlayerSetting.screenFullScreen),
          _toggle(ref,
              title: AppStrings.of(context).pssKeepOn,
              subtitle: AppStrings.of(context).pssKeepOnSub,
              setting: PlayerSetting.screenKeepOn),
          SettingsSectionHeader(AppStrings.of(context).pssBrightness),
          _toggle(ref,
              title: AppStrings.of(context).pssAutoBrightness,
              subtitle: AppStrings.of(context).pssAutoBrightnessSub,
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
            final label = cur < 0 ? AppStrings.of(context).pssFollowSystem : '$cur%';
            return SettingsNavTile(
              title: AppStrings.of(context).pssDefaultBrightness,
              subtitle: AppStrings.of(context).pssDefaultBrightnessSub(label),
              onTap: () async {
                // -1 represents 'follow system'; slider is 0..100.
                final picked = await showSettingsSliderDialog(
                  context: context,
                  title: AppStrings.of(context).pssDefaultBrightness,
                  currentValue: cur < 0 ? -1.0 : cur.toDouble(),
                  min: -1,
                  max: 100,
                  divisions: 101,
                  valueLabel: (v) =>
                      v < 0 ? AppStrings.of(context).pssFollowSystem : '${v.round()}%',
                );
                if (picked == null) return;
                await ref.read(extraSettingsProvider.notifier).setInt(
                    IntSetting.defaultBrightnessPct, picked.round());
              },
            );
          }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
