import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Brightness indicator — vertical bar attached to RIGHT screen edge.
/// (MX Player parity — Mercy 2026 screen recording).
/// Shows: % at top, blue vertical fill bar, sun icon at bottom.
class BrightnessIndicator extends StatelessWidget {
  final double value; // 0.0 - 1.0

  const BrightnessIndicator({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    final percent = (value * 100).round();
    final iconData = value > 0.66
        ? Icons.brightness_high
        : value > 0.33
            ? Icons.brightness_medium
            : Icons.brightness_low;

    return Align(
      alignment: Alignment.centerRight,
      child: IgnorePointer(
        child: Padding(
          padding: const EdgeInsets.only(right: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Percentage label
              Text(
                '$percent%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  fontFeatures: [FontFeature.tabularFigures()],
                  shadows: [
                    Shadow(
                      color: Colors.black87,
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Vertical fill bar
              SizedBox(
                width: 4,
                height: 120,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Stack(
                    children: [
                      Container(color: AppColors.white30),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          alignment: Alignment.bottomCenter,
                          heightFactor: value.clamp(0.0, 1.0),
                          child: Container(color: AppColors.accentBlue),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Sun icon
              Icon(
                iconData,
                color: Colors.white,
                size: 22,
                shadows: const [
                  Shadow(
                    color: Colors.black87,
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
