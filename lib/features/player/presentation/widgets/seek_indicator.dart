import 'package:flutter/material.dart';

/// Phase 17: MX Player parity seek indicator (V1 t=24, V2 t=20 reference).
///
/// Design:
/// - HUGE white target time (44pt) at vertical center of the video
/// - SMALL bracketed delta below it (16pt, white, in square brackets)
/// - NO background box, NO icon, NO blue accent
/// - Just text overlaid directly on the dimmed video
class SeekIndicator extends StatelessWidget {
  final Duration delta;
  final Duration targetPosition;

  const SeekIndicator({
    super.key,
    required this.delta,
    required this.targetPosition,
  });

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _formatDelta(Duration d) {
    final isNegative = d.isNegative;
    final abs = d.abs();
    final h = abs.inHours;
    final m = abs.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = abs.inSeconds.remainder(60).toString().padLeft(2, '0');
    final formatted = h > 0 ? '$h:$m:$s' : '$m:$s';
    return '[${isNegative ? '-' : '+'}$formatted]';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Target time — huge white text, no background
            Text(
              _formatDuration(targetPosition),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 44,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
                height: 1.0,
                shadows: [
                  // Slight shadow for legibility over bright video
                  Shadow(blurRadius: 4, color: Colors.black54),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Delta in square brackets — smaller white
            Text(
              _formatDelta(delta),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w400,
                fontFeatures: [FontFeature.tabularFigures()],
                height: 1.0,
                shadows: [
                  Shadow(blurRadius: 4, color: Colors.black54),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
