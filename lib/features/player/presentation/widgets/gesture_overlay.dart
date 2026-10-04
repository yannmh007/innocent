import 'package:flutter/material.dart';

import '../gestures/player_gesture_engine.dart';

/// The player's touch surface: raw pointer events in, MX Player's gestures
/// out. The decisions are all in [PlayerGestureEngine] (and its tests);
/// this widget only measures the player, knows where the system gesture
/// zones and the subtitle are, and passes the results on.
///
/// - Tap → controls; double tap left / right → seek, stacking per tap;
///   double tap centre → play / pause
/// - 1-finger vertical swipe: left half brightness, right half volume
///   (past 100 % into the booster, when it is on)
/// - 1-finger horizontal swipe → seek
/// - 2-finger vertical swipe → playback speed
/// - Pinch → zoom; the two fingers' midpoint pans the zoomed picture
/// - Long press → speed slider, drag without lifting
/// - On the subtitle: drag moves it, swipe steps lines, pinch sizes it
class GestureOverlay extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback onDoubleTapRewind;
  final VoidCallback onDoubleTapForward;
  final VoidCallback onDoubleTapCenter;

  /// A side double tap and each further tap of the run ([count] 1, 2, 3…).
  /// When set, it replaces [onDoubleTapRewind] / [onDoubleTapForward].
  final void Function(bool forward, int count)? onDoubleTapStacked;
  final ValueChanged<double> onBrightnessDelta;
  final ValueChanged<double> onVolumeDelta;
  final VoidCallback onSeekStart;
  final ValueChanged<int> onSeekUpdate;
  final VoidCallback onSeekEnd;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;
  final ValueChanged<Offset>? onLongPressMoveGlobal;
  final ValueChanged<double>? onPinchUpdate; // scaleDelta (multiplicative)
  final VoidCallback? onPinchEnd;

  /// Two-finger pan of the zoomed picture: the move, and the player's size.
  final void Function(Offset delta, Size view)? onPan;
  final VoidCallback? onSpeedStart;
  final ValueChanged<int>? onSpeedSteps;
  final VoidCallback? onSpeedEnd;
  final ValueChanged<double>? onSubtitleMove;
  final ValueChanged<double>? onSubtitleScale;
  final ValueChanged<int>? onSubtitleStep;
  final VoidCallback? onSubtitleEnd;

  /// The band the visible subtitle occupies in a player of the given size,
  /// or null when no subtitle is on screen. Asked at each touch.
  final Rect? Function(Size size)? subtitleBand;

  /// The film's length (keeps the seek scale sane on a short clip).
  final Duration duration;

  /// Per-gesture switches (Settings → Controls), as in MX Player.
  final bool brightnessSwipeEnabled;
  final bool volumeSwipeEnabled;
  final bool seekSwipeEnabled;
  final bool pinchZoomEnabled;
  final bool longPressSpeedEnabled;
  final bool doubleTapEnabled;
  final bool twoFingerSpeedEnabled;
  final bool panEnabled;
  final bool subtitleGesturesEnabled;

  const GestureOverlay({
    super.key,
    required this.onTap,
    required this.onDoubleTapRewind,
    required this.onDoubleTapForward,
    required this.onDoubleTapCenter,
    this.onDoubleTapStacked,
    required this.onBrightnessDelta,
    required this.onVolumeDelta,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    this.onLongPressMoveGlobal,
    this.onPinchUpdate,
    this.onPinchEnd,
    this.onPan,
    this.onSpeedStart,
    this.onSpeedSteps,
    this.onSpeedEnd,
    this.onSubtitleMove,
    this.onSubtitleScale,
    this.onSubtitleStep,
    this.onSubtitleEnd,
    this.subtitleBand,
    this.duration = Duration.zero,
    this.brightnessSwipeEnabled = true,
    this.volumeSwipeEnabled = true,
    this.seekSwipeEnabled = true,
    this.pinchZoomEnabled = true,
    this.longPressSpeedEnabled = true,
    this.doubleTapEnabled = true,
    this.twoFingerSpeedEnabled = true,
    this.panEnabled = true,
    this.subtitleGesturesEnabled = true,
  });

  @override
  State<GestureOverlay> createState() => _GestureOverlayState();
}

class _GestureOverlayState extends State<GestureOverlay> {
  late final PlayerGestureEngine _engine =
      PlayerGestureEngine(callbacks: const GestureCallbacks());
  Size _size = Size.zero;

  /// The top of the screen belongs to the notification shade even with the
  /// status bar hidden (an immersive player): no swipe starts there.
  static const double _shadeZone = 24;

  void _configure(BuildContext context) {
    final w = widget;
    final sys = MediaQuery.systemGestureInsetsOf(context);
    _engine
      ..size = _size
      ..duration = w.duration
      ..noSwipeInsets = EdgeInsets.fromLTRB(
        sys.left,
        sys.top > _shadeZone ? sys.top : _shadeZone,
        sys.right,
        sys.bottom,
      )
      ..switches = GestureSwitches(
        brightness: w.brightnessSwipeEnabled,
        volume: w.volumeSwipeEnabled,
        seek: w.seekSwipeEnabled,
        doubleTap: w.doubleTapEnabled,
        longPress: w.longPressSpeedEnabled,
        pinch: w.pinchZoomEnabled,
        pan: w.panEnabled,
        twoFingerSpeed: w.twoFingerSpeedEnabled,
        subtitles: w.subtitleGesturesEnabled,
      )
      ..callbacks = GestureCallbacks(
        onTap: w.onTap,
        onDoubleTap: (zone, count) {
          switch (zone) {
            case TapZone.centre:
              w.onDoubleTapCenter();
              break;
            case TapZone.left:
            case TapZone.right:
              final forward = zone == TapZone.right;
              final stacked = w.onDoubleTapStacked;
              if (stacked != null) {
                stacked(forward, count);
              } else if (forward) {
                w.onDoubleTapForward();
              } else {
                w.onDoubleTapRewind();
              }
          }
        },
        onLongPressStart: w.onLongPressStart,
        onLongPressMove: w.onLongPressMoveGlobal,
        onLongPressEnd: w.onLongPressEnd,
        onBrightness: w.onBrightnessDelta,
        onVolume: w.onVolumeDelta,
        onSeekStart: w.onSeekStart,
        onSeekUpdate: w.onSeekUpdate,
        onSeekEnd: w.onSeekEnd,
        onSpeedStart: w.onSpeedStart,
        onSpeedSteps: w.onSpeedSteps,
        onSpeedEnd: w.onSpeedEnd,
        onPinch: w.onPinchUpdate == null
            ? null
            : (scale, _) => w.onPinchUpdate!(scale),
        onPan: w.onPan == null ? null : (d) => w.onPan!(d, _size),
        onPinchEnd: w.onPinchEnd,
        onSubtitleMove: w.onSubtitleMove,
        onSubtitleScale: w.onSubtitleScale,
        onSubtitleSeek: w.onSubtitleStep,
        onSubtitleEnd: w.onSubtitleEnd,
      );
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _size = Size(c.maxWidth, c.maxHeight);
      _configure(context);
      // A raw Listener carries no semantics, where the GestureDetector it
      // replaced gave TalkBack a tap action on the whole player. Kept: a
      // TalkBack double tap anywhere still shows or hides the controls.
      return Semantics(
        container: true,
        onTap: widget.onTap,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (_engine.size.isEmpty) return;
            // Where the subtitle is right now, for a gesture starting now.
            _engine.subtitleBand = widget.subtitleGesturesEnabled
                ? widget.subtitleBand?.call(_size)
                : null;
            _engine.pointerDown(e.pointer, e.localPosition, e.timeStamp,
                global: e.position);
          },
          onPointerMove: (e) => _engine.pointerMove(
              e.pointer, e.localPosition, e.timeStamp,
              global: e.position),
          onPointerUp: (e) =>
              _engine.pointerUp(e.pointer, e.localPosition, e.timeStamp),
          onPointerCancel: (e) => _engine.pointerCancel(e.pointer),
          child: const SizedBox.expand(),
        ),
      );
    });
  }
}
