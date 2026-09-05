import 'package:flutter/material.dart';

/// Phase 18: Zoom percentage indicator — MX Player parity (Function PDF p7).
///
/// HUGE white "156%" text overlaid directly on the video, NO background box,
/// shadows for legibility.
class ZoomIndicator extends StatelessWidget {
  final double value; // 1.0 = 100%

  const ZoomIndicator({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    final pct = (value * 100).round();
    return Center(
      child: IgnorePointer(
        child: Text(
          '$pct%',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 44,
            fontWeight: FontWeight.w600,
            shadows: [
              Shadow(blurRadius: 4, color: Colors.black54),
            ],
          ),
        ),
      ),
    );
  }
}
