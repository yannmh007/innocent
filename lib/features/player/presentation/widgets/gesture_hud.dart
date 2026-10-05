import 'package:flutter/material.dart';

import '../player_provider.dart';

/// A gesture's value over the video, MX style: large white text with a
/// shadow and no box ("1.5x", "120%"), a small caption under it.
class GestureValueText extends StatelessWidget {
  const GestureValueText(
      {super.key, required this.value, this.caption, this.valueSize = 44});

  final String value;
  final String? caption;

  /// The value's text size: 44 for a number, smaller for a word.
  final double valueSize;

  static const _shadow = [Shadow(blurRadius: 4, color: Colors.black54)];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: valueSize,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
                shadows: _shadow,
              ),
            ),
            if (caption != null)
              Text(
                caption!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  shadows: _shadow,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The stacked double tap's running total on its side: a soft half-disc
/// from the edge with the direction and "30 s", restarting its pulse on
/// every tap (YouTube / MX).
class DoubleTapRippleView extends StatelessWidget {
  const DoubleTapRippleView({super.key, required this.ripple});

  final DoubleTapRipple ripple;

  @override
  Widget build(BuildContext context) {
    final forward = ripple.forward;
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth * 0.36;
        return Align(
          alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
          child: TweenAnimationBuilder<double>(
            key: ValueKey(ripple.serial),
            tween: Tween(begin: 0.6, end: 1),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            builder: (context, t, child) =>
                Opacity(opacity: t.clamp(0.0, 1.0), child: child),
            // Half an ellipse as tall as the player: an arc from the edge in
            // either orientation (a circular radius made a pill in portrait,
            // where the player is taller than the band is wide).
            child: ClipRRect(
              borderRadius: forward
                  ? BorderRadius.horizontal(
                      left: Radius.elliptical(w, c.maxHeight / 2))
                  : BorderRadius.horizontal(
                      right: Radius.elliptical(w, c.maxHeight / 2)),
              child: Container(
                width: w,
                height: c.maxHeight,
                color: Colors.white.withValues(alpha: 0.12),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${ripple.seconds} s',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                        shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}
