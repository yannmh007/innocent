import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > Player > Style
/// Player UI style options.
///
/// Phase 41: toggles persist via [playerSettingsProvider].
class PlayerStyleScreen extends ConsumerWidget {
  const PlayerStyleScreen({super.key});

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
      appBar: AppBar(title: Text(AppStrings.of(context).styleTitle)),
      body: ListView(
        children: [
          SettingsSectionHeader(AppStrings.of(context).psTitleBar),
          _toggle(ref,
              title: AppStrings.of(context).psShowTitle,
              subtitle: AppStrings.of(context).psShowTitleSub,
              setting: PlayerSetting.styleShowTitle),
          _toggle(ref,
              title: AppStrings.of(context).psShowClock,
              subtitle: AppStrings.of(context).psShowClockSub,
              setting: PlayerSetting.styleShowClock),
          _toggle(ref,
              title: AppStrings.of(context).psShowSourceUrl,
              subtitle: AppStrings.of(context).psShowSourceUrlSub,
              setting: PlayerSetting.styleShowSourceUrl),
          SettingsSectionHeader(AppStrings.of(context).psLayout),
          // Audit fix (standard high-quality): wire toolbar position
          // to StringSetting.toolbarPosition. player_screen reads
          // the value and places the top bar at the top of the
          // screen ('top', default) or just above the playback
          // controls ('bottom') — useful for one-handed phone-grip
          // ergonomics where back/title need to be in thumb reach.
          Builder(builder: (ctx) {
            final s = AppStrings.of(context);
            final labels = <String, String>{
              'top': s.psToolbarTop,
              'bottom': s.psToolbarBottom,
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.toolbarPosition);
            final curLabel = labels[cur] ?? labels['top']!;
            return SettingsNavTile(
              title: s.psToolbarPosition,
              subtitle: s.psToolbarPositionSub(curLabel),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.psToolbarPosition,
                  options: labels.values.toList(),
                  currentValue: curLabel,
                );
                if (picked == null) return;
                final v = labels.entries
                    .where((e) => e.value == picked)
                    .map((e) => e.key)
                    .firstOrNull;
                if (v == null) return;
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setStr(StringSetting.toolbarPosition, v);
              },
            );
          }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
