import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

import '../../../../core/localization/app_strings.dart';
/// Full-screen overlay showing all player gestures (Phase 14).
/// Tappable to dismiss.
class GesturesHelpOverlay extends StatelessWidget {
  const GesturesHelpOverlay({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => const GesturesHelpOverlay(),
    );
  }

  static const _gestures = <_Gesture>[
    _Gesture(
      icon: Icons.touch_app,
      title: 'Tap',
      description: 'Show / hide player controls',
    ),
    _Gesture(
      icon: Icons.touch_app_outlined,
      title: 'Double tap left',
      description: 'Seek backward 10 seconds',
    ),
    _Gesture(
      icon: Icons.pause_circle_outline,
      title: 'Double tap center',
      description: 'Play / pause',
    ),
    _Gesture(
      icon: Icons.touch_app_outlined,
      title: 'Double tap right',
      description: 'Seek forward 10 seconds',
    ),
    _Gesture(
      icon: Icons.swipe_vertical,
      title: 'Vertical swipe left',
      description: 'Adjust brightness',
    ),
    _Gesture(
      icon: Icons.swipe_vertical,
      title: 'Vertical swipe right',
      description: 'Adjust volume',
    ),
    _Gesture(
      icon: Icons.swipe,
      title: 'Horizontal swipe',
      description: 'Seek video timeline',
    ),
    _Gesture(
      icon: Icons.zoom_out_map,
      title: 'Pinch (2 fingers)',
      description: 'Zoom video 25% to 1000%',
    ),
    _Gesture(
      icon: Icons.timer_outlined,
      title: 'Long press + drag',
      description: 'Quick playback speed change',
    ),
    _Gesture(
      icon: Icons.volume_up_outlined,
      title: 'Volume hardware key',
      description: 'Seek ±10s (only in player)',
    ),
    _Gesture(
      icon: Icons.headphones_outlined,
      title: 'Headset button',
      description: 'Play / pause',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        color: Colors.transparent,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.touch_app,
                        color: AppColors.accentBlue, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(AppStrings.of(context).playerGestures,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.separated(
                    itemCount: _gestures.length,
                    separatorBuilder: (_, __) => const Divider(
                      height: 16,
                      color: Colors.white12,
                    ),
                    itemBuilder: (_, i) => _GestureItem(_gestures[i]),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(AppStrings.of(context).tapToDismiss,
                    style: const TextStyle(
                      color: AppColors.darkOnSurfaceMuted,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Gesture {
  final IconData icon;
  final String title;
  final String description;
  const _Gesture({
    required this.icon,
    required this.title,
    required this.description,
  });
}

class _GestureItem extends StatelessWidget {
  final _Gesture gesture;
  const _GestureItem(this.gesture);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.accentBlue15,
            shape: BoxShape.circle,
          ),
          child: Icon(gesture.icon, color: AppColors.accentBlue, size: 20),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                gesture.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                gesture.description,
                style: const TextStyle(
                  color: AppColors.darkOnSurfaceMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
