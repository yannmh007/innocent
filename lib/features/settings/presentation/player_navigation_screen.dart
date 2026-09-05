import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/preferences_provider.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > Player > Navigation
/// Seeking settings, forward/backward buttons, etc.
///
/// Phase 41: toggles persist via [playerSettingsProvider].
class PlayerNavigationScreen extends ConsumerWidget {
  const PlayerNavigationScreen({super.key});

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
      appBar: AppBar(title: Text(AppStrings.of(context).navigationTitle)),
      body: ListView(
        children: [
          const SettingsSectionHeader('Seek Bar'),
          _toggle(ref,
              title: 'Show seek bar',
              subtitle: 'Display the seek bar at the bottom of the player.',
              setting: PlayerSetting.navShowSeekBar),
          _toggle(ref,
              title: 'Seek bar preview',
              subtitle: 'Show thumbnail preview while dragging the seek bar.',
              setting: PlayerSetting.navSeekBarPreview),
          // Audit fix (standard high-quality): wire seek interval to
          // the existing `doubleTapSeekSeconds` preference. The
          // backing storage was already in place — only the UI tile
          // was unwired.
          Builder(builder: (ctx) {
            final current = ref
                .watch(preferencesProvider)
                .doubleTapSeekSeconds;
            final label = '$current seconds';
            return SettingsNavTile(
              title: 'Seek interval',
              subtitle:
                  'Default seek for double-tap and on-screen forward/back. Currently: $label',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Seek Interval',
                  options: const [
                    '5 seconds',
                    '10 seconds',
                    '15 seconds',
                    '30 seconds',
                    '60 seconds',
                  ],
                  currentValue: label,
                );
                if (picked == null) return;
                final n = int.tryParse(picked.split(' ').first);
                if (n == null) return;
                await ref
                    .read(preferencesProvider.notifier)
                    .setDoubleTapSeek(n);
              },
            );
          }),
          const SettingsSectionHeader('Buttons'),
          _toggle(ref,
              title: 'Show previous/next buttons',
              subtitle: 'Display previous and next buttons on the player.',
              setting: PlayerSetting.navShowPrevNext),
          // Audit fix (standard high-quality): wire forward/back
          // button behaviour to StringSetting.forwardBackButtonAction.
          // The two physical buttons share one logical action choice:
          //   nextPrev → next / previous file in queue (default)
          //   seek10   → seek ±10 s
          //   seek30   → seek ±30 s
          //   seek60   → seek ±60 s
          // player_provider reads this and routes onNext / onPrevious.
          Builder(builder: (ctx) {
            const optMap = <String, String>{
              'Next / Previous video': 'nextPrev',
              'Seek ±10 seconds': 'seek10',
              'Seek ±30 seconds': 'seek30',
              'Seek ±60 seconds': 'seek60',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.forwardBackButtonAction);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        const MapEntry('Next / Previous video', 'nextPrev'))
                .key;
            return SettingsNavTile(
              title: 'Forward / Backward buttons',
              subtitle: 'What the on-screen ◀▶ buttons do. Currently: $curLabel',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Forward / Backward Action',
                  options: optMap.keys.toList(),
                  currentValue: curLabel,
                );
                if (picked == null) return;
                final v = optMap[picked];
                if (v == null) return;
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setStr(StringSetting.forwardBackButtonAction, v);
              },
            );
          }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
