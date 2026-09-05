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
          const SettingsSectionHeader('Title Bar'),
          _toggle(ref,
              title: 'Show title',
              subtitle: 'Display video title on the player screen.',
              setting: PlayerSetting.styleShowTitle),
          _toggle(ref,
              title: 'Show system clock',
              subtitle: 'Display current time on the player screen.',
              setting: PlayerSetting.styleShowClock),
          _toggle(ref,
              title: 'Show battery level',
              subtitle: 'Display battery percentage on the player screen.',
              setting: PlayerSetting.styleShowBattery),
          _toggle(ref,
              title: 'Show source URL',
              subtitle: 'Display source URL/path for network play.',
              setting: PlayerSetting.styleShowSourceUrl),
          const SettingsSectionHeader('Layout'),
          _toggle(ref,
              title: 'Compact mode',
              subtitle: 'Use compact player controls layout.',
              setting: PlayerSetting.styleCompactMode),
          // Audit fix (standard high-quality): wire toolbar position
          // to StringSetting.toolbarPosition. player_screen reads
          // the value and places the top bar at the top of the
          // screen ('top', default) or just above the playback
          // controls ('bottom') — useful for one-handed phone-grip
          // ergonomics where back/title need to be in thumb reach.
          Builder(builder: (ctx) {
            const optMap = <String, String>{
              'Top (default)': 'top',
              'Bottom (within thumb reach)': 'bottom',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.toolbarPosition);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        const MapEntry('Top (default)', 'top'))
                .key;
            return SettingsNavTile(
              title: 'Toolbar position',
              subtitle:
                  'Where the title bar sits on the player. Currently: $curLabel',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Toolbar Position',
                  options: optMap.keys.toList(),
                  currentValue: curLabel,
                );
                if (picked == null) return;
                final v = optMap[picked];
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
