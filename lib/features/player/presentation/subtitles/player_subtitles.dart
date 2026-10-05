import 'package:flutter/material.dart';

import '../../../../core/services/diagnostics/playback_log.dart';
import '../../../../core/services/video_player/media_kit_player_service.dart';
import '../../../../core/services/video_player/subtitle_look.dart';
import '../gestures/subtitle_band.dart';

/// The subtitle, drawn by the player over the video (see [SubtitleLook] for
/// why not by libmpv or media_kit): in the user's size, colours, outline,
/// shadow, background and position, outside the zoom so Crop, 100 % and a
/// pinch never cut it off or enlarge it. The secondary track, when there
/// is one, goes at the top of the picture, as libmpv puts it.
class PlayerSubtitles extends StatelessWidget {
  const PlayerSubtitles({
    super.key,
    required this.service,
    required this.picture,
    this.padding = EdgeInsets.zero,
  });

  final MediaKitPlayerService service;

  /// The picture's rectangle on screen (video_geometry.dart).
  final Rect picture;

  /// Kept clear at the top and bottom (system bars, the bottom controls).
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, c) {
        final view = Size(c.maxWidth, c.maxHeight);
        return ValueListenableBuilder<SubtitleLook>(
          valueListenable: service.subtitleLook,
          builder: (context, look, _) => StreamBuilder<List<String>>(
            stream: service.subtitleStream,
            initialData: service.subtitleLines,
            builder: (context, snap) {
              final lines = snap.data ?? const <String>[];
              final main = lines.isNotEmpty ? lines[0].trim() : '';
              final second = lines.length > 1 ? lines[1].trim() : '';
              if (main.isEmpty && second.isEmpty) {
                return const SizedBox.shrink();
              }
              final g = subtitleGeometry(
                  view: view, picture: picture, look: look, padding: padding);
              _labTrace(main, g, view);
              return Stack(children: [
                if (main.isNotEmpty)
                  Positioned(
                    left: g.box.left,
                    width: g.box.width,
                    bottom: view.height - g.bottom,
                    child: SubtitleText(main, look: look, geometry: g),
                  ),
                if (second.isNotEmpty)
                  Positioned(
                    left: g.box.left,
                    width: g.box.width,
                    top: (g.box.top + g.fontSize * 0.4)
                        .clamp(padding.top, view.height)
                        .toDouble(),
                    child: SubtitleText(second, look: look, geometry: g),
                  ),
              ]);
            },
          ),
        );
      }),
    );
  }
}

// DEVICE LAB BUILDS ONLY: where each new subtitle line was drawn, so the
// lab can check it stayed on screen in every screen mode.
String? _labLast;
void _labTrace(String text, SubtitleGeometry g, Size view) {
  if (!PlaybackLog.labTrace) return;
  final line = 'LAB subtitle "${text.replaceAll('\n', ' / ')}" '
      'bottom=${g.bottom.toStringAsFixed(0)} of ${view.height.toStringAsFixed(0)} '
      'font=${g.fontSize.toStringAsFixed(1)} '
      'box=${g.box.left.toStringAsFixed(0)}..${g.box.right.toStringAsFixed(0)}';
  if (line == _labLast) return;
  _labLast = line;
  debugPrint(line);
}

/// One subtitle block: the outline drawn as a stroke under the fill, as
/// libmpv draws it, with the shadow and the background box when set.
class SubtitleText extends StatelessWidget {
  const SubtitleText(this.text,
      {super.key, required this.look, required this.geometry});

  final String text;
  final SubtitleLook look;
  final SubtitleGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: geometry.fontSize,
      height: 1.25,
      fontFamily: look.font,
      fontWeight: look.bold ? FontWeight.w700 : FontWeight.w500,
      decoration: TextDecoration.none,
    );
    Widget text(TextStyle style) => Text(
          this.text,
          textAlign: TextAlign.center,
          // The size is the user's subtitle setting; the system font scale
          // is not applied on top of it a second time.
          textScaler: TextScaler.noScaling,
          style: style,
        );
    final hasBack = look.backColor.a > 0;
    return Stack(alignment: Alignment.center, children: [
      if (geometry.outline > 0 && look.borderColor.a > 0)
        text(base.copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = geometry.outline * 2
            ..strokeJoin = StrokeJoin.round
            ..color = look.borderColor,
        )),
      text(base.copyWith(
        color: look.color,
        backgroundColor: hasBack ? look.backColor : null,
        shadows: geometry.shadow > 0 && look.shadowColor.a > 0
            ? [
                Shadow(
                  offset: Offset(geometry.shadow, geometry.shadow),
                  blurRadius: geometry.shadow,
                  color: look.shadowColor,
                ),
              ]
            : null,
      )),
    ]);
  }
}
