import 'package:flutter/material.dart';

/// Gesture overlay - emits semantic gesture events for the player.
///
/// Behavior:
/// - Single tap → toggle controls
/// - Double tap (left 1/3) → rewind 10s
/// - Double tap (middle 1/3) → play/pause
/// - Double tap (right 1/3) → forward 10s
/// - 1-finger vertical swipe (left half) → brightness
/// - 1-finger vertical swipe (right half) → volume
/// - 1-finger horizontal swipe → seek
/// - 2-finger pinch → zoom (PDF page 7)
/// - Long press → speed slider, drag-without-release adjusts (PDF page 9)
class GestureOverlay extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback onDoubleTapRewind;
  final VoidCallback onDoubleTapForward;
  final VoidCallback onDoubleTapCenter;
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

  final double verticalSensitivity;
  final double seekSecondsPerWidth;

  /// Phase 45: per-gesture gates wired to Settings → Controls. When a
  /// flag is false the corresponding gesture is silently ignored,
  /// exactly like MX Player's per-gesture toggles.
  final bool brightnessSwipeEnabled;
  final bool volumeSwipeEnabled;
  final bool seekSwipeEnabled;
  final bool pinchZoomEnabled;
  final bool longPressSpeedEnabled;

  const GestureOverlay({
    super.key,
    required this.onTap,
    required this.onDoubleTapRewind,
    required this.onDoubleTapForward,
    required this.onDoubleTapCenter,
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
    this.verticalSensitivity = 0.6,
    this.seekSecondsPerWidth = 90.0,
    this.brightnessSwipeEnabled = true,
    this.volumeSwipeEnabled = true,
    this.seekSwipeEnabled = true,
    this.pinchZoomEnabled = true,
    this.longPressSpeedEnabled = true,
  });

  @override
  State<GestureOverlay> createState() => _GestureOverlayState();
}

enum _GestureType { none, brightness, volume, seek, pinch }

class _GestureOverlayState extends State<GestureOverlay> {
  _GestureType _type = _GestureType.none;
  Offset _startPosition = Offset.zero;
  double _accumDx = 0;
  double _accumDy = 0;
  double _lastScale = 1.0;
  static const double _gestureThreshold = 16.0;

  void _handleDoubleTap(TapDownDetails details) {
    final width = context.size?.width ?? 1;
    final x = details.localPosition.dx;
    if (x < width / 3) {
      widget.onDoubleTapRewind();
    } else if (x > width * 2 / 3) {
      widget.onDoubleTapForward();
    } else {
      widget.onDoubleTapCenter();
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startPosition = details.localFocalPoint;
    _accumDx = 0;
    _accumDy = 0;
    _lastScale = 1.0;
    _type = _GestureType.none;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Two+ fingers → pinch zoom mode
    if (details.pointerCount >= 2) {
      // Phase 45: respect user's pinch-zoom gate.
      if (!widget.pinchZoomEnabled) return;
      if (_type != _GestureType.pinch) {
        // Cancel any pending pan gesture
        if (_type == _GestureType.seek) widget.onSeekEnd();
        _type = _GestureType.pinch;
        _lastScale = 1.0;
      }
      // Compute incremental scale change since last update
      final scaleDelta = details.scale / _lastScale;
      _lastScale = details.scale;
      widget.onPinchUpdate?.call(scaleDelta);
      return;
    }

    // One finger → pan / swipe
    _accumDx = details.focalPointDelta.dx + _accumDx;
    _accumDy = details.focalPointDelta.dy + _accumDy;

    if (_type == _GestureType.none) {
      final dx = _accumDx.abs();
      final dy = _accumDy.abs();
      if (dx < _gestureThreshold && dy < _gestureThreshold) return;

      if (dx > dy) {
        // Phase 45: respect seek-swipe gate.
        if (!widget.seekSwipeEnabled) return;
        _type = _GestureType.seek;
        widget.onSeekStart();
      } else {
        final width = context.size?.width ?? 1;
        final side = _startPosition.dx < width / 2;
        // Phase 45: respect brightness / volume gates. If the chosen
        // side is gated off, abandon this gesture rather than fall
        // through to the wrong side.
        if (side && !widget.brightnessSwipeEnabled) return;
        if (!side && !widget.volumeSwipeEnabled) return;
        _type = side ? _GestureType.brightness : _GestureType.volume;
      }
    }

    switch (_type) {
      case _GestureType.brightness:
      case _GestureType.volume:
        final height = context.size?.height ?? 1;
        final delta = -details.focalPointDelta.dy /
            (height * widget.verticalSensitivity);
        if (_type == _GestureType.brightness) {
          widget.onBrightnessDelta(delta);
        } else {
          widget.onVolumeDelta(delta);
        }
        break;
      case _GestureType.seek:
        final width = context.size?.width ?? 1;
        final seconds =
            (_accumDx / width * widget.seekSecondsPerWidth).round();
        widget.onSeekUpdate(seconds);
        break;
      case _GestureType.pinch:
      case _GestureType.none:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_type == _GestureType.seek) {
      widget.onSeekEnd();
    } else if (_type == _GestureType.pinch) {
      widget.onPinchEnd?.call();
    }
    _type = _GestureType.none;
    _accumDx = 0;
    _accumDy = 0;
    _lastScale = 1.0;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: _handleDoubleTap,
      onDoubleTap: () {},
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd: _onScaleEnd,
      // Phase 45: only wire long-press callbacks when the user enabled
      // the gesture. When `longPressSpeedEnabled` is false we pass null
      // to GestureDetector, leaving the long-press unbound so the system
      // text-selection / OS gestures aren't swallowed either.
      onLongPressStart: widget.longPressSpeedEnabled
          ? (_) => widget.onLongPressStart()
          : null,
      onLongPressMoveUpdate: widget.longPressSpeedEnabled
          ? (details) {
              widget.onLongPressMoveGlobal?.call(details.globalPosition);
            }
          : null,
      onLongPressEnd: widget.longPressSpeedEnabled
          ? (_) => widget.onLongPressEnd()
          : null,
      child: const SizedBox.expand(),
    );
  }
}
