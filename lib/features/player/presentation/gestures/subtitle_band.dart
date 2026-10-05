import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../../core/services/video_player/subtitle_look.dart';

/// Where the subtitle goes on screen — one answer for the layer that draws
/// it (player_subtitles.dart) and for the gestures that grab it.
///
/// Placed on the part of the picture that is on screen, so a Crop or a
/// pinch zoom never pushes it off the edge with the overflow, and sized
/// from the SCREEN, not the picture, so zooming does not enlarge it (MX).
/// libmpv's arithmetic: sizes are pixels of a 720-line screen, here the
/// screen's shorter side (the same physical size in both orientations);
/// the text's bottom is at `sub-pos` % of the picture's height, lifted by
/// `sub-margin-y`.
class SubtitleGeometry {
  const SubtitleGeometry({
    required this.fontSize,
    required this.outline,
    required this.shadow,
    required this.bottom,
    required this.box,
  });

  /// Text size, outline width and shadow offset, in dp.
  final double fontSize;
  final double outline;
  final double shadow;

  /// Where the last line's bottom sits, in dp from the player's top.
  final double bottom;

  /// The horizontal band the lines are centred and wrapped in (its top and
  /// bottom are the visible picture's).
  final Rect box;

  /// A finger-sized band around [lines] lines of text: padded by [touchPad]
  /// and kept off the outer tenth of the picture on each side, where the
  /// brightness and volume swipes start.
  Rect touchBand(int lines, {double touchPad = 20}) {
    final textH = fontSize * 1.25 * lines.clamp(1, 4);
    return Rect.fromLTRB(
      box.left + box.width * 0.06,
      bottom - textH - touchPad,
      box.right - box.width * 0.06,
      bottom + touchPad,
    );
  }
}

SubtitleGeometry subtitleGeometry({
  required Size view,
  required Rect picture,
  required SubtitleLook look,
  EdgeInsets padding = EdgeInsets.zero,
}) {
  final screen = Offset.zero & view;
  var visible = picture.intersect(screen);
  if (visible.width <= 0 || visible.height <= 0) visible = screen;
  final k = math.min(view.width, view.height) / 720;
  final scale = look.scale.clamp(0.1, 4.0);
  final fontSize = math.max(8.0, look.fontSize * scale * k);
  final outline = look.borderSize * scale * k;
  final shadow = look.shadowOffset * scale * k;
  final lowest = view.height - padding.bottom - 2;
  final highest = math.min(lowest, padding.top + fontSize * 1.4);
  final bottom =
      (visible.top + visible.height * look.position / 100 - look.marginY * k)
          .clamp(highest, lowest)
          .toDouble();
  final width = visible.width * 0.94;
  final box = Rect.fromLTWH(
      visible.center.dx - width / 2, visible.top, width, visible.height);
  return SubtitleGeometry(
    fontSize: fontSize,
    outline: outline,
    shadow: shadow,
    bottom: bottom,
    box: box,
  );
}
