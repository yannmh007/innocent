import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Volume indicator — vertical bar attached to LEFT screen edge.
/// (MX Player parity — Mercy 2026 screen recording).
/// Shows: % at top, blue vertical fill bar, speaker icon at bottom.
class VolumeIndicator extends StatelessWidget {
  final double value; // 0.0 - 1.0

  const VolumeIndicator({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    final percent = (value * 100).round();
    final iconData = value <= 0.0
        ? Icons.volume_off
        : value > 0.66
            ? Icons.volume_up
            : value > 0.33
                ? Icons.volume_down
                : Icons.volume_mute;

    return Align(
      alignment: Alignment.centerLeft,
      child: IgnorePointer(
        child: Padding(
          padding: const EdgeInsets.only(left: 20),
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
              // Vertical bar with fill
              SizedBox(
                width: 4,
                height: 120,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Stack(
                    children: [
                      // Background track
                      Container(color: AppColors.white30),
                      // Filled portion (bottom-up)
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
              // Speaker icon
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
