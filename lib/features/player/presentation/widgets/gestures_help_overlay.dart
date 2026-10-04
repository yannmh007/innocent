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

  /// Every gesture, as Settings → Controls names it (docs/player_gestures.md).
  /// The volume keys move the system volume — they never seek (this list
  /// used to say "Seek ±10s", which MainActivity has never done).
  static List<_Gesture> _gestures(AppStrings s) => <_Gesture>[
        _Gesture(icon: Icons.touch_app, title: s.gtTap, description: s.gtTapSub),
        _Gesture(
            icon: Icons.fast_forward_rounded,
            title: s.gtDoubleTap,
            description: s.gtDoubleTapSub),
        _Gesture(
            icon: Icons.swipe_vertical,
            title: s.gtBrightness,
            description: s.gtBrightnessSub),
        _Gesture(
            icon: Icons.swipe_vertical,
            title: s.gtVolume,
            description: s.gtVolumeSub),
        _Gesture(icon: Icons.swipe, title: s.gtSeek, description: s.gtSeekSub),
        _Gesture(
            icon: Icons.speed, title: s.gtSpeed, description: s.gtSpeedSub),
        _Gesture(
            icon: Icons.timer_outlined,
            title: s.gtLongPress,
            description: s.gtLongPressSub),
        _Gesture(
            icon: Icons.zoom_out_map,
            title: s.gtPinch,
            description: s.gtPinchSub),
        _Gesture(icon: Icons.pan_tool_outlined, title: s.gtPan, description: s.gtPanSub),
        _Gesture(
            icon: Icons.subtitles_outlined,
            title: s.gtSubtitle,
            description: s.gtSubtitleSub),
        _Gesture(
            icon: Icons.volume_up_outlined,
            title: s.gtVolumeKey,
            description: s.gtVolumeKeySub),
        _Gesture(
            icon: Icons.headphones_outlined,
            title: s.gtHeadset,
            description: s.gtHeadsetSub),
      ];

  @override
  Widget build(BuildContext context) {
    final gestures = _gestures(AppStrings.of(context));
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
                    itemCount: gestures.length,
                    separatorBuilder: (_, __) => const Divider(
                      height: 16,
                      color: Colors.white12,
                    ),
                    itemBuilder: (_, i) => _GestureItem(gestures[i]),
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
          decoration: const BoxDecoration(
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
