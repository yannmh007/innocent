import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/ui/app_sheet.dart';
import '../video_adjust.dart';
/// Display Settings sheet — brightness, contrast, saturation, hue sliders
class DisplaySettingsSheet extends ConsumerWidget {
  const DisplaySettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showAppModalBottomSheet(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      // Sideways the default 9/16 of the screen held two of the four
      // sliders; the rest were cut off with nothing to scroll.
      isScrollControlled: true,
      constraints: tallSheetConstraints(context),
      builder: (_) => const DisplaySettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The picture's own adjustments (video_adjust.dart): the sliders used
    // to move numbers nothing read.
    final adjust = ref.watch(videoAdjustProvider);
    final set = ref.read(videoAdjustProvider.notifier);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Expanded(
                  child: Text(AppStrings.of(context).displaySettingsTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: adjust.isNeutral
                      ? null
                      : () => set.state = const VideoAdjust(),
                  child: Text(AppStrings.of(context).reset,
                      style: TextStyle(
                          color: adjust.isNeutral
                              ? AppColors.white60
                              : AppColors.primaryBlue)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildSlider(
              label: AppStrings.of(context).pwBrightness,
              value: adjust.brightness,
              icon: Icons.brightness_6,
              onChanged: (v) =>
                  set.state = set.state.copyWith(brightness: v),
            ),
            _buildSlider(
              label: AppStrings.of(context).pwContrast,
              value: adjust.contrast,
              icon: Icons.contrast,
              onChanged: (v) => set.state = set.state.copyWith(contrast: v),
            ),
            _buildSlider(
              label: AppStrings.of(context).pwSaturation,
              value: adjust.saturation,
              icon: Icons.color_lens_outlined,
              onChanged: (v) =>
                  set.state = set.state.copyWith(saturation: v),
            ),
            _buildSlider(
              label: AppStrings.of(context).pwHue,
              value: adjust.hue,
              icon: Icons.palette_outlined,
              onChanged: (v) => set.state = set.state.copyWith(hue: v),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required IconData icon,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: Colors.white54, size: 20),
          const SizedBox(width: 12),
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: const SliderThemeData(
                activeTrackColor: AppColors.primaryBlue,
                inactiveTrackColor: AppColors.white15,
                thumbColor: AppColors.primaryBlue,
                trackHeight: 2,
                thumbShape:
                    RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value,
                min: -1.0,
                max: 1.0,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              '${(value * 100).round()}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppColors.white60,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
