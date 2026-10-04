import 'package:flutter/painting.dart';

/// Where libmpv draws the subtitle, near enough for a finger to find it.
///
/// libmpv renders subtitles into the video frame, so they sit in the video's
/// rectangle on screen ([fit] of [video] in [player]), not the player's. Its
/// defaults: a 55-point font scaled to a 720-line frame (about 8 % of the
/// frame's height per line, times `sub-scale`), the text's bottom at
/// `sub-pos` % of the frame from the top, lifted by a 22-line margin (3 %).
/// The band is padded by [touchPad] dp so the finger need not land on the
/// letters, and kept clear of the outer tenth on each side, which is where
/// brightness and volume swipes start.
Rect subtitleBandFor({
  required Size player,
  required Size? video,
  required BoxFit fit,
  required int positionPct,
  required double scale,
  required int lines,
  double touchPad = 20,
}) {
  final frame = video == null || video.isEmpty
      ? Offset.zero & player
      : Alignment.center.inscribe(
          applyBoxFit(fit, video, player).destination, Offset.zero & player);
  final lineH = frame.height * 0.08 * scale.clamp(0.3, 2.0);
  final textH = lineH * lines.clamp(1, 4);
  final bottom =
      frame.top + frame.height * (positionPct.clamp(0, 100) / 100) -
          frame.height * 0.03;
  final top = bottom - textH;
  final visible = Offset.zero & player;
  return Rect.fromLTRB(
    frame.left + frame.width * 0.1,
    top - touchPad,
    frame.right - frame.width * 0.1,
    bottom + touchPad,
  ).intersect(visible);
}
