import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'aspect_ratio_mode.dart';

/// Where the picture sits on screen for each of MX Player's screen modes
/// (docs/player_playback_modes.md).
///
/// The texture is always laid out "contain" (whole frame, letterboxed) —
/// or "fill" for Stretch — and every other mode is a SCALE of that about
/// the centre, plus the pan. So Crop is a zoom until the bars are gone,
/// not a cut: the parts past the screen's edge are still there, a
/// two-finger drag brings them into view, and the subtitles (drawn
/// outside this transform) never go with them.

/// The size [video] takes when fitted whole inside [view].
Size containSize(Size view, Size? video) {
  if (video == null || video.isEmpty || view.isEmpty) return view;
  final s = math.min(view.width / video.width, view.height / video.height);
  return Size(video.width * s, video.height * s);
}

/// How much the contained picture is enlarged in [mode].
///
/// * fit — 1, the whole frame;
/// * stretch — 1, but the texture is drawn [BoxFit.fill] beforehand;
/// * crop — just enough that no bar is left (the picture covers [view]);
/// * original — one video pixel on one screen pixel ([devicePixelRatio]
///   physical pixels per dp);
/// * custom — the user's own pinch zoom, [customScale].
double screenModeScale({
  required AspectRatioMode mode,
  required Size view,
  required Size? video,
  required double devicePixelRatio,
  double customScale = 1.0,
}) {
  final c = containSize(view, video);
  if (c.isEmpty) return 1.0;
  switch (mode) {
    case AspectRatioMode.fit:
    case AspectRatioMode.stretch:
      return 1.0;
    case AspectRatioMode.crop:
      return math.max(view.width / c.width, view.height / c.height);
    case AspectRatioMode.original:
      if (video == null || video.isEmpty || devicePixelRatio <= 0) return 1.0;
      return (video.width / devicePixelRatio) / c.width;
    case AspectRatioMode.custom:
      return customScale;
  }
}

/// The picture's size on screen at [scale] in [mode].
Size pictureSize({
  required AspectRatioMode mode,
  required Size view,
  required Size? video,
  required double scale,
}) {
  final base =
      mode == AspectRatioMode.stretch ? view : containSize(view, video);
  return Size(base.width * scale, base.height * scale);
}

/// The picture's rectangle on screen: centred, then moved by [offset].
Rect pictureRect(Size view, Size picture, Offset offset) {
  final c = view.center(Offset.zero) + offset;
  return Rect.fromCenter(
      center: c, width: picture.width, height: picture.height);
}

/// How far a picture of size [picture] may be dragged inside [view]: no
/// further than its own edge, so a black bar is never pulled into view on
/// an axis where the picture is larger than the screen, and not at all on
/// an axis where it is smaller.
Offset clampPan(Offset offset, Size picture, Size view) {
  final mx = math.max(0.0, (picture.width - view.width) / 2);
  final my = math.max(0.0, (picture.height - view.height) / 2);
  return Offset(
    offset.dx.clamp(-mx, mx).toDouble(),
    offset.dy.clamp(-my, my).toDouble(),
  );
}
