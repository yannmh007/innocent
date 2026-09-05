import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

import '../../../../core/localization/app_strings.dart';
/// Display Settings sheet — brightness, contrast, saturation, hue sliders
class DisplaySettingsSheet extends StatefulWidget {
  const DisplaySettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const DisplaySettingsSheet(),
    );
  }

  @override
  State<DisplaySettingsSheet> createState() => _DisplaySettingsSheetState();
}

class _DisplaySettingsSheetState extends State<DisplaySettingsSheet> {
  double _brightness = 0.0;
  double _contrast = 0.0;
  double _saturation = 0.0;
  double _hue = 0.0;

  void _reset() {
    setState(() {
      _brightness = 0.0;
      _contrast = 0.0;
      _saturation = 0.0;
      _hue = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Text(AppStrings.of(context).displaySettingsTitle,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _reset,
                  child: Text(AppStrings.of(context).reset,
                      style: TextStyle(color: AppColors.primaryBlue)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildSlider(
              label: 'Brightness',
              value: _brightness,
              icon: Icons.brightness_6,
              onChanged: (v) => setState(() => _brightness = v),
            ),
            _buildSlider(
              label: 'Contrast',
              value: _contrast,
              icon: Icons.contrast,
              onChanged: (v) => setState(() => _contrast = v),
            ),
            _buildSlider(
              label: 'Saturation',
              value: _saturation,
              icon: Icons.color_lens_outlined,
              onChanged: (v) => setState(() => _saturation = v),
            ),
            _buildSlider(
              label: 'Hue',
              value: _hue,
              icon: Icons.palette_outlined,
              onChanged: (v) => setState(() => _hue = v),
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
              data: SliderThemeData(
                activeTrackColor: AppColors.primaryBlue,
                inactiveTrackColor: AppColors.white15,
                thumbColor: AppColors.primaryBlue,
                trackHeight: 2,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
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
              style: TextStyle(
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
