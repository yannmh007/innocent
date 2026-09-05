import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Speed indicator - shown on left edge when playback speed != 1.0
class SpeedIndicator extends StatelessWidget {
  final double speed;

  const SpeedIndicator({super.key, required this.speed});

  @override
  Widget build(BuildContext context) {
    final speedLabel = speed == speed.toInt().toDouble()
        ? '${speed.toInt()}X'
        : '${speed.toStringAsFixed(1)}X';

    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
        decoration: BoxDecoration(
          color: AppColors.playerOverlayDark,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.white20,
            width: 1,
          ),
        ),
        child: Text(
          speedLabel,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
