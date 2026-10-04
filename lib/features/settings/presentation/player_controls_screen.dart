import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_dialogs.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Settings > Player > Controls
/// Touch actions, gestures, lock mode, etc.
///
/// Phase 41: toggles persist via [playerSettingsProvider].
class PlayerControlsScreen extends ConsumerWidget {
  const PlayerControlsScreen({super.key});

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
    final s = AppStrings.of(context);
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(s.controlsTitle)),
      body: ListView(
        children: [
          SettingsSectionHeader(s.gtSection),
          _toggle(ref,
              title: s.gtBrightness,
              subtitle: s.gtBrightnessSub,
              setting: PlayerSetting.ctlSwipeBrightness),
          _toggle(ref,
              title: s.gtVolume,
              subtitle: s.gtVolumeSub,
              setting: PlayerSetting.ctlSwipeVolume),
          _toggle(ref,
              title: s.gtSeek,
              subtitle: s.gtSeekSub,
              setting: PlayerSetting.ctlSwipeSeek),
          _toggle(ref,
              title: s.gtDoubleTap,
              subtitle: s.gtDoubleTapSub,
              setting: PlayerSetting.ctlDoubleTapSeek),
          _toggle(ref,
              title: s.gtLongPress,
              subtitle: s.gtLongPressSub,
              setting: PlayerSetting.ctlLongPressSpeed),
          _toggle(ref,
              title: s.gtSpeed,
              subtitle: s.gtSpeedSub,
              setting: PlayerSetting.ctlTwoFingerSpeed),
          _toggle(ref,
              title: s.gtPinch,
              subtitle: s.gtPinchSub,
              setting: PlayerSetting.ctlPinchZoom),
          _toggle(ref,
              title: s.gtPan,
              subtitle: s.gtPanSub,
              setting: PlayerSetting.ctlZoomPan),
          _toggle(ref,
              title: s.gtSubtitle,
              subtitle: s.gtSubtitleSub,
              setting: PlayerSetting.ctlSubtitleGestures),
          _toggle(ref,
              title: s.gtTap,
              subtitle: s.gtTapSub,
              setting: PlayerSetting.ctlTapToggle),
          const SettingsSectionHeader('Lock'),
          // Audit fix (standard high-quality): wire lock mode to
          // StringSetting.lockMode. Three behaviours:
          //   all      → hide controls + ignore gestures (default)
          //   rotation → freeze rotation only; controls/gestures
          //              remain usable
          //   touch    → hide controls + disable all gestures
          //              (most restrictive)
          // Player_provider reads lockMode when applying lock state.
          Builder(builder: (ctx) {
            const optMap = <String, String>{
              'Lock all (default)': 'all',
              'Lock rotation only': 'rotation',
              'Lock touch only': 'touch',
            };
            final cur = ref
                .watch(extraSettingsProvider)
                .getStr(StringSetting.lockMode);
            final curLabel = optMap.entries
                .firstWhere((e) => e.value == cur,
                    orElse: () =>
                        const MapEntry('Lock all (default)', 'all'))
                .key;
            return SettingsNavTile(
              title: 'Lock mode',
              subtitle: 'What "Lock" does on the player. Currently: $curLabel',
              onTap: () async {
                final picked = await showSettingsListDialog(
                  context: context,
                  title: 'Lock Mode',
                  options: optMap.keys.toList(),
                  currentValue: curLabel,
                );
                if (picked == null) return;
                final v = optMap[picked];
                if (v == null) return;
                await ref
                    .read(extraSettingsProvider.notifier)
                    .setStr(StringSetting.lockMode, v);
              },
            );
          }),
          _toggle(ref,
              title: 'Lock screen on rotation',
              subtitle: 'Automatically lock screen when device rotates.',
              setting: PlayerSetting.ctlLockOnRotation),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
