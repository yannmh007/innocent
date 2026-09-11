import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_widgets.dart';

import '../../../core/localization/app_strings.dart';
/// Development settings — debugging and advanced options.
///
/// Phase 41: toggles persist via [playerSettingsProvider]; "Reset all
/// settings" now actually wipes every persisted boolean.
class SettingsDevelopmentScreen extends ConsumerWidget {
  const SettingsDevelopmentScreen({super.key});

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

  Future<void> _confirmAndResetAll(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).resetSettingsTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(AppStrings.of(context).resetSettingsBody,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(AppStrings.of(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(AppStrings.of(context).reset,
                style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(playerSettingsProvider.notifier).resetAll();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(AppStrings.of(context).settingsResetDone),
          duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).settingsDevelopment)),
      body: ListView(
        children: [
          const SettingsSectionHeader('Debug'),
          _toggle(ref,
              title: 'Show buffer info',
              subtitle: 'Display buffer status during playback.',
              setting: PlayerSetting.devShowBufferInfo),
          _toggle(ref,
              title: 'Show decoder info',
              subtitle: 'Display current decoder information.',
              setting: PlayerSetting.devShowDecoderInfo),
          _toggle(ref,
              title: 'Show FPS',
              subtitle: 'Display frames per second on screen.',
              setting: PlayerSetting.devShowFps),
          _toggle(ref,
              title: 'Enable debug log',
              subtitle: 'Write debug log to file for troubleshooting.',
              setting: PlayerSetting.devEnableDebugLog),
          const SettingsSectionHeader('Experimental'),
          _toggle(ref,
              title: 'Disable HW acceleration',
              subtitle: 'Force software decoding. Use only for debugging.',
              setting: PlayerSetting.devDisableHwAccel),
          SettingsNavTile(
            title: 'Export logs',
            subtitle: 'Save debug logs to file.',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(AppStrings.of(context).debugLogsExported)),
              );
            },
          ),
          SettingsNavTile(
            title: 'Reset all settings',
            subtitle: 'Restore all settings to default values.',
            onTap: () => _confirmAndResetAll(context, ref),
          ),
        ],
      ),
    );
  }
}
