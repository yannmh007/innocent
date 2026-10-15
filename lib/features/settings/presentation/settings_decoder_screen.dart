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
          SettingsSectionHeader(AppStrings.of(context).sdHw),
          // Phase 45 (audit refined, build 63): MX Player V3's
          // `omxdecoder.2` selector — 4-mode HW decoder strategy.
          // Different from per-stream decHwLocal/decHwNetwork toggles
          // (which are added below). This is the OVERALL "when to
          // attempt HW decode" policy.
          Builder(builder: (ctx) {
            final optMap = <String, String>{
              AppStrings.of(context).sdAutoDefault: 'auto',
              AppStrings.of(context).sdNeverHw: 'never',
              AppStrings.of(context).sdLocalOnly: 'localOnly',
              AppStrings.of(context).sdAlwaysHw: 'everywhere',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.omxDecoderMode);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () => MapEntry(AppStrings.of(context).sdAutoDefault, 'auto'))
                .key;
            return SettingsNavTile(
              title: AppStrings.of(context).sdStrategy,
              subtitle: curLabel,
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).sdStrategy,
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
              title: AppStrings.of(context).sdHwPlusLocal,
              subtitle:
                  AppStrings.of(context).sdHwPlusLocalSub,
              setting: PlayerSetting.decHwLocal),
          _toggle(ref,
              title: AppStrings.of(context).sdHwPlusNet,
              subtitle:
                  AppStrings.of(context).sdHwPlusNetSub,
              setting: PlayerSetting.decHwNetwork),
          _toggle(ref,
              title: AppStrings.of(context).sdTryHw,
              subtitle: AppStrings.of(context).sdTryHwSub,
              setting: PlayerSetting.decTryHw),
          _toggle(ref,
              title: AppStrings.of(context).sdTryHwPlus,
              subtitle: AppStrings.of(context).sdTryHwPlusSub,
              setting: PlayerSetting.decTryHwPlus),
          SettingsSectionHeader(AppStrings.of(context).sdSw),
          _toggle(ref,
              title: AppStrings.of(context).sdSwLocal,
              subtitle: AppStrings.of(context).sdSwLocalSub,
              setting: PlayerSetting.decSwLocal),
          _toggle(ref,
              title: AppStrings.of(context).sdSwNet,
              subtitle:
                  AppStrings.of(context).sdSwNetSub,
              setting: PlayerSetting.decSwNetwork),
          // Audit fix (standard high-quality): wire CPU Core Limit
          // to `IntSetting.videoDecoderThreads` which the player
          // service feeds into libmpv's `vd-lavc-threads` on open.
          // 0 = libmpv auto. Useful on thermally constrained
          // devices to prevent decoder thrashing the CPU.
          Builder(builder: (ctx) {
            final optMap = <String, int>{
              AppStrings.of(context).sdAutoRecommended: 0,
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
                        MapEntry(AppStrings.of(context).sdAutoRecommended, 0))
                .key;
            return SettingsNavTile(
              title: AppStrings.of(context).sdCores,
              subtitle: AppStrings.of(context).sdCoresSub(curLabel),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).sdCores,
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
          _toggle(ref,
              title: AppStrings.of(context).sdSpeedup,
              subtitle: AppStrings.of(context).sdSpeedupSub,
              setting: PlayerSetting.decSpeedupTricks),
          SettingsSectionHeader(AppStrings.of(context).sdGeneral),
          _toggle(ref,
              title: AppStrings.of(context).sdEfficient,
              subtitle: AppStrings.of(context).sdEfficientSub,
              setting: PlayerSetting.decEfficientOutput),
          _toggle(ref,
              title: AppStrings.of(context).sdDeinterlace,
              subtitle:
                  AppStrings.of(context).sdDeinterlaceSub,
              setting: PlayerSetting.decDeinterlace),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
