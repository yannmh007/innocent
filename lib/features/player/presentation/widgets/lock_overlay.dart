import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../player_provider.dart';

/// Lock overlay — shown when the player is locked.
///
/// MX Player V3 parity:
/// - Bottom-right: round unlock button
/// - Bottom-left: current time + remaining time (so the user can still see
///   playback position without unlocking)
class LockOverlay extends ConsumerWidget {
  final VoidCallback onUnlock;

  const LockOverlay({super.key, required this.onUnlock});

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerControllerProvider);
    final hasDuration = state.duration > Duration.zero;
    return Stack(
      children: [
        // Bottom-left: time readout (Phase 43)
        Positioned(
          bottom: 32,
          left: 24,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.black55,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _fmt(state.position),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (hasDuration) ...[
                  const SizedBox(width: 8),
                  Text(
                    '-${_fmt(state.duration - state.position)}',
                    style: const TextStyle(
                      color: AppColors.white70,
                      fontSize: 13,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // Bottom-right: unlock button
        Positioned(
          bottom: 24,
          right: 24,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onUnlock,
              borderRadius: BorderRadius.circular(28),
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.playerOverlayDark,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.white30,
                    width: 1,
                  ),
                ),
                child: const Icon(
                  Icons.lock_outline,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
