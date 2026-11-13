import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// Every gesture of the player (⋮ → Tutorial; docs/player_gestures.md).
///
/// A player sheet like every other menu of the player: frosted glass, a
/// bottom sheet upright and a panel from the right sideways, closed by a
/// drag, a tap on the picture or Back. It was a page of its own — the film
/// behind 87 % black, its own header and close button, blue discs, its own
/// type and "Tap anywhere to dismiss" — the last menu with a look of its
/// own (docs/devices_2026_11.md, Phase 2 item 5, 13 Nov).
class GesturesHelpOverlay extends StatelessWidget {
  const GesturesHelpOverlay({super.key});

  static Future<void> show(BuildContext context) =>
      showPlayerSheet<void>(context,
          builder: (_) => const GesturesHelpOverlay());

  /// Every gesture, as Settings → Controls names it (docs/player_gestures.md).
  /// The volume keys move the system volume — they never seek (this list
  /// used to say "Seek ±10s", which MainActivity has never done).
  static List<_Gesture> _gestures(AppStrings s) => <_Gesture>[
        _Gesture(
            icon: Icons.touch_app, title: s.gtTap, description: s.gtTapSub),
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
        _Gesture(
            icon: Icons.pan_tool_outlined,
            title: s.gtPan,
            description: s.gtPanSub),
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
    final s = AppStrings.of(context);
    final pad = PlayerUi.pad(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerSheetHeader(title: s.playerGestures),
        Flexible(
          child: PanelScroll(
            padding: EdgeInsets.fromLTRB(pad - 4, 8, pad - 4, 16),
            children: [for (final g in _gestures(s)) _GestureRow(g)],
          ),
        ),
      ],
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

/// One gesture: its icon, what to do, what it does, in the player's row
/// type. Not a button, but it takes focus, so a keyboard or a remote can
/// walk the list and the list scrolls with it (FocusRingLayer shows where).
class _GestureRow extends StatelessWidget {
  const _GestureRow(this.gesture);

  final _Gesture gesture;

  @override
  Widget build(BuildContext context) {
    return Focus(
      child: MergeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(gesture.icon,
                      size: 22, color: PlayerUi.textSecondary),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(gesture.title, style: PlayerUi.rowTitle),
                      const SizedBox(height: 2),
                      Text(gesture.description, style: PlayerUi.rowValue),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
