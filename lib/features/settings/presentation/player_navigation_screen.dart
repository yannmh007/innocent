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
          SettingsSectionHeader(AppStrings.of(context).pnSeekBar),
          _toggle(ref,
              title: AppStrings.of(context).pnShowSeekBar,
              subtitle: AppStrings.of(context).pnShowSeekBarSub,
              setting: PlayerSetting.navShowSeekBar),
          _toggle(ref,
              title: AppStrings.of(context).pnSeekPreview,
              subtitle: AppStrings.of(context).pnSeekPreviewSub,
              setting: PlayerSetting.navSeekBarPreview),
          // Audit fix (standard high-quality): wire seek interval to
          // the existing `doubleTapSeekSeconds` preference. The
          // backing storage was already in place — only the UI tile
          // was unwired.
          Builder(builder: (ctx) {
            final current = ref
                .watch(preferencesProvider)
                .doubleTapSeekSeconds;
            final s = AppStrings.of(context);
            final label = s.secondsCount(current);
            const choices = <int>[5, 10, 15, 30, 60];
            final options = [for (final n in choices) s.secondsCount(n)];
            return SettingsNavTile(
              title: s.pnSeekInterval,
              subtitle: s.pnSeekIntervalSub(label),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: s.pnSeekInterval,
                  options: options,
                  currentValue: label,
                );
                if (picked == null) return;
                final i = options.indexOf(picked);
                if (i < 0) return;
                final n = choices[i];
                await ref
                    .read(preferencesProvider.notifier)
                    .setDoubleTapSeek(n);
              },
            );
          }),
          SettingsSectionHeader(AppStrings.of(context).pnButtons),
          _toggle(ref,
              title: AppStrings.of(context).pnShowPrevNext,
              subtitle: AppStrings.of(context).pnShowPrevNextSub,
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
            final optMap = <String, String>{
              AppStrings.of(context).pnNextPrev: 'nextPrev',
              AppStrings.of(context).pnSeekPm(10): 'seek10',
              AppStrings.of(context).pnSeekPm(30): 'seek30',
              AppStrings.of(context).pnSeekPm(60): 'seek60',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.forwardBackButtonAction);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        MapEntry(AppStrings.of(context).pnNextPrev, 'nextPrev'))
                .key;
            return SettingsNavTile(
              title: AppStrings.of(context).pnFwdBack,
              subtitle: AppStrings.of(context).pnFwdBackSub(curLabel),
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: AppStrings.of(context).pnFwdBack,
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
