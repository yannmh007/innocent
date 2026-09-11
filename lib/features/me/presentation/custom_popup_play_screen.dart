import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
/// Custom Pop-up Play Controls matching MX Player (UI PDF page 13).
/// 2 radio options: Previous/Next (Default) and Fast Forward/Rewind.
///
/// Phase 41: choice persists via [playerSettingsProvider]
/// ([PlayerSetting.customPopupFastForward]) so it survives an app restart.
class CustomPopupPlayScreen extends ConsumerWidget {
  const CustomPopupPlayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fastForward = ref
        .watch(playerSettingsProvider)
        .get(PlayerSetting.customPopupFastForward);
    final selectedControl = fastForward ? 'ff_rew' : 'prev_next';

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).popupPlay)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(AppStrings.of(context).popupPlayControls,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 20),
          _radioOption(
            ref,
            'Previous/Next(Default)',
            'prev_next',
            selectedControl,
          ),
          const SizedBox(height: 4),
          _radioOption(
            ref,
            'Fast Forward/Rewind',
            'ff_rew',
            selectedControl,
          ),
        ],
      ),
    );
  }

  Widget _radioOption(
    WidgetRef ref,
    String label,
    String value,
    String selectedControl,
  ) {
    void select() {
      ref.read(playerSettingsProvider.notifier).setValue(
            PlayerSetting.customPopupFastForward,
            value == 'ff_rew',
          );
    }

    return InkWell(
      onTap: select,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            Radio<String>(
              value: value,
              groupValue: selectedControl,
              activeColor: AppColors.primaryBlue,
              fillColor: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.selected)) {
                  return AppColors.primaryBlue;
                }
                return Colors.white54;
              }),
              onChanged: (_) => select(),
            ),
          ],
        ),
      ),
    );
  }
}
