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
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).controlsTitle)),
      body: ListView(
        children: [
          const SettingsSectionHeader('Touch Gestures'),
          _toggle(ref,
              title: 'Swipe to adjust brightness',
              subtitle:
                  'Swipe up/down on the left side of the screen to adjust brightness.',
              setting: PlayerSetting.ctlSwipeBrightness),
          _toggle(ref,
              title: 'Swipe to adjust volume',
              subtitle:
                  'Swipe up/down on the right side of the screen to adjust volume.',
              setting: PlayerSetting.ctlSwipeVolume),
          _toggle(ref,
              title: 'Swipe to seek',
              subtitle:
                  'Swipe left/right on the screen to seek forward/backward.',
              setting: PlayerSetting.ctlSwipeSeek),
          _toggle(ref,
              title: 'Double-tap to seek',
              subtitle:
                  'Double-tap on left/right side to seek backward/forward by 10 seconds.',
              setting: PlayerSetting.ctlDoubleTapSeek),
          _toggle(ref,
              title: 'Long press to speed up',
              subtitle:
                  'Long press and hold to temporarily increase playback speed to 2x.',
              setting: PlayerSetting.ctlLongPressSpeed),
          _toggle(ref,
              title: 'Pinch to zoom',
              subtitle: 'Pinch two fingers to zoom in/out on video.',
              setting: PlayerSetting.ctlPinchZoom),
          _toggle(ref,
              title: 'Tap to show/hide controls',
              subtitle:
                  'Single tap on the screen to toggle player controls visibility.',
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
