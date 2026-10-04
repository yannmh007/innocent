import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/painting.dart' show EdgeInsets, Offset, Rect, Size;

/// Which third of the player a double tap landed in.
enum TapZone { left, centre, right }

/// What a two-finger gesture turned out to be.
enum _Two { pending, pinch, speed, subtitlePinch, none }

/// What a one-finger drag turned out to be.
enum _One {
  pending,
  brightness,
  volume,
  seek,
  subtitleMove,
  subtitleSeek,
  longPress,
  none,
}

/// Which gestures are on (Settings → Player → Gestures).
class GestureSwitches {
  const GestureSwitches({
    this.brightness = true,
    this.volume = true,
    this.seek = true,
    this.doubleTap = true,
    this.longPress = true,
    this.pinch = true,
    this.pan = true,
    this.twoFingerSpeed = true,
    this.subtitles = true,
  });

  final bool brightness;
  final bool volume;
  final bool seek;
  final bool doubleTap;
  final bool longPress;
  final bool pinch;
  final bool pan;
  final bool twoFingerSpeed;
  final bool subtitles;
}

/// Everything the engine reports. Each is optional: a gesture whose callback
/// is null is simply not recognised.
class GestureCallbacks {
  const GestureCallbacks({
    this.onTap,
    this.onDoubleTap,
    this.onLongPressStart,
    this.onLongPressMove,
    this.onLongPressEnd,
    this.onBrightness,
    this.onVolume,
    this.onVerticalEnd,
    this.onSeekStart,
    this.onSeekUpdate,
    this.onSeekEnd,
    this.onSpeedStart,
    this.onSpeedSteps,
    this.onSpeedEnd,
    this.onPinch,
    this.onPan,
    this.onPinchEnd,
    this.onSubtitleMove,
    this.onSubtitleScale,
    this.onSubtitleSeek,
    this.onSubtitleEnd,
  });

  final void Function()? onTap;

  /// [count] is 1 for a double tap, then 2, 3… for each further tap on the
  /// same side while the run lasts (YouTube / VLC "stacked" seeking).
  final void Function(TapZone zone, int count)? onDoubleTap;

  final void Function()? onLongPressStart;
  final void Function(Offset global)? onLongPressMove;
  final void Function()? onLongPressEnd;

  /// A change as a fraction of the full range (+ = up / more).
  final void Function(double delta)? onBrightness;
  final void Function(double delta)? onVolume;
  final void Function()? onVerticalEnd;

  final void Function()? onSeekStart;

  /// Seconds from where the swipe started (+ = forward).
  final void Function(int seconds)? onSeekUpdate;
  final void Function()? onSeekEnd;

  final void Function()? onSpeedStart;

  /// Whole speed steps from where the two-finger swipe started (+ = faster).
  final void Function(int steps)? onSpeedSteps;
  final void Function()? onSpeedEnd;

  /// Multiplicative zoom change since the last call, and the pinch's centre.
  final void Function(double scaleDelta, Offset focal)? onPinch;

  /// Movement of the two fingers' midpoint since the last call, in dp.
  final void Function(Offset delta)? onPan;
  final void Function()? onPinchEnd;

  /// Subtitle moved by a fraction of the player's height (+ = down).
  final void Function(double delta)? onSubtitleMove;
  final void Function(double scaleDelta)? onSubtitleScale;

  /// One line forward (+1) or back (−1).
  final void Function(int direction)? onSubtitleSeek;
  final void Function()? onSubtitleEnd;
}

/// The player's touch gestures, decided from raw pointer events.
///
/// Rules and their sources are in docs/player_gestures.md. In short:
/// swipes never start inside the system-gesture zones (Back, Home, the
/// notification shade); a direction is taken only once it is clear; ranges
/// are in dp, not screen fractions, so a tablet feels like a phone; double
/// taps on one side stack; two fingers either change speed (moving together)
/// or zoom and pan (spreading); a gesture that starts on a subtitle moves,
/// sizes or steps the subtitle.
///
/// Pure Dart apart from [Timer]: the widget feeds it pointer events and
/// supplies the geometry; tests drive it with a fake clock.
class PlayerGestureEngine {
  PlayerGestureEngine({required this.callbacks});

  GestureCallbacks callbacks;
  GestureSwitches switches = const GestureSwitches();

  /// The player's size in dp.
  Size size = Size.zero;

  /// Where a swipe may not start: the system-gesture insets, plus room at
  /// the top for the notification shade.
  EdgeInsets noSwipeInsets = EdgeInsets.zero;

  /// The film's length, to keep the seek scale sane for a short clip.
  Duration duration = Duration.zero;

  /// The visible subtitle's band, or null when no subtitle is on screen.
  Rect? subtitleBand;

  // Thresholds (dp / ms). Flutter's kTouchSlop is 18, kDoubleTapTimeout
  // 300 ms, kDoubleTapSlop 100, kLongPressTimeout 500 ms.
  static const double slop = 18;
  static const double twoFingerSlop = 24;
  static const double doubleTapSlop = 100;
  static const Duration doubleTapTimeout = Duration(milliseconds: 300);
  static const Duration longPressTimeout = Duration(milliseconds: 500);

  /// How long a run of stacked taps stays open after the last one.
  static const Duration stackWindow = Duration(milliseconds: 600);

  /// |major| must exceed this × |minor| to take a direction.
  static const double directionRatio = 1.5;

  /// Finger travel per speed step on a two-finger swipe.
  static const double speedStepDp = 24;

  /// Finger travel per subtitle line on a subtitle swipe.
  static const double subtitleStepDp = 64;

  static const double _maxSeekWidthDp = 600;

  /// Full brightness / volume range in dp of finger travel.
  double get verticalRangeDp =>
      (size.height * 0.6).clamp(200.0, 480.0).toDouble();

  /// Seconds a swipe across [seekWidthDp] moves: 90, or the whole clip when
  /// it is shorter (but at least 10 s).
  double get secondsPerSeekWidth {
    final d = duration.inMilliseconds / 1000.0;
    if (d <= 0) return 90;
    return math.min(90.0, math.max(10.0, d));
  }

  double get seekWidthDp => math.min(size.width, _maxSeekWidthDp);

  // ── state ───────────────────────────────────────────────────────────

  final Map<int, Offset> _down = {};
  final Map<int, Offset> _now = {};
  Offset? _downGlobal;

  _One _one = _One.pending;
  _Two _two = _Two.none;
  bool _swipeAllowed = true;
  bool _ignoreUntilAllUp = false;
  bool _moved = false;

  Timer? _longPressTimer;
  Timer? _singleTapTimer;
  Offset? _pendingTapAt;
  Duration? _pendingTapUpAt;

  TapZone? _stackZone;
  int _stackCount = 0;
  Duration? _stackLastAt;

  double _lastVerticalY = 0;
  int _lastSubtitleSteps = 0;
  int _lastSpeedSteps = 0;
  double _twoSpacing0 = 0;
  double _twoLastSpacing = 0;
  Offset _twoMid0 = Offset.zero;
  Offset _twoLastMid = Offset.zero;
  bool _twoOnSubtitle = false;

  /// The latest event's timestamp (PointerEvent.timeStamp): the same clock
  /// Flutter's own recognisers use, and one a test can set.
  Duration _time = Duration.zero;

  // ── input ───────────────────────────────────────────────────────────

  void pointerDown(int id, Offset local, Duration time, {Offset? global}) {
    _time = time;
    _down[id] = local;
    _now[id] = local;
    if (_down.length == 1) {
      _beginOne(local, global ?? local);
    } else if (_down.length == 2) {
      _beginTwo();
    } else {
      // A third finger: whatever two were doing, stop it cleanly.
      _endAll();
      _ignoreUntilAllUp = true;
    }
  }

  void pointerMove(int id, Offset local, Duration time, {Offset? global}) {
    if (!_down.containsKey(id)) return;
    _time = time;
    _now[id] = local;
    if (_ignoreUntilAllUp) return;
    if (_down.length == 1) {
      _moveOne(local, global ?? local);
    } else if (_down.length == 2) {
      _moveTwo();
    }
  }

  void pointerUp(int id, Offset local, Duration time) {
    if (!_down.containsKey(id)) return;
    _time = time;
    _now[id] = local;
    final wasCount = _down.length;
    if (wasCount == 1 && !_ignoreUntilAllUp) {
      _upOne(local);
    } else if (wasCount == 2) {
      _endTwo();
      // The finger left behind must not turn into a seek.
      _ignoreUntilAllUp = true;
    }
    _down.remove(id);
    _now.remove(id);
    if (_down.isEmpty) {
      _ignoreUntilAllUp = false;
      _two = _Two.none;
    }
  }

  void pointerCancel(int id) {
    if (!_down.containsKey(id)) return;
    _endAll();
    _down.remove(id);
    _now.remove(id);
    if (_down.isEmpty) {
      _ignoreUntilAllUp = false;
      _two = _Two.none;
    }
  }

  void dispose() {
    _longPressTimer?.cancel();
    _singleTapTimer?.cancel();
  }

  // ── one finger ──────────────────────────────────────────────────────

  bool _inNoSwipeZone(Offset p) =>
      p.dx < noSwipeInsets.left ||
      p.dx > size.width - noSwipeInsets.right ||
      p.dy < noSwipeInsets.top ||
      p.dy > size.height - noSwipeInsets.bottom;

  TapZone _zoneOf(Offset p) {
    final w = size.width <= 0 ? 1 : size.width;
    if (p.dx < w / 3) return TapZone.left;
    if (p.dx > w * 2 / 3) return TapZone.right;
    return TapZone.centre;
  }

  void _beginOne(Offset local, Offset global) {
    _one = _One.pending;
    _moved = false;
    _downGlobal = global;
    _swipeAllowed = !_inNoSwipeZone(local);
    _lastVerticalY = local.dy;
    _lastSubtitleSteps = 0;
    _longPressTimer?.cancel();
    if (switches.longPress && callbacks.onLongPressStart != null) {
      _longPressTimer = Timer(longPressTimeout, () {
        if (_down.length == 1 && !_moved && _one == _One.pending) {
          _one = _One.longPress;
          // A held finger is not a tap, nor half of a double tap.
          _cancelPendingTap();
          callbacks.onLongPressStart?.call();
        }
      });
    }
  }

  void _moveOne(Offset local, Offset global) {
    final start = _down.values.first;
    final d = local - start;
    if (_one == _One.longPress) {
      callbacks.onLongPressMove?.call(global);
      return;
    }
    if (!_moved && d.distance > slop) {
      _moved = true;
      _longPressTimer?.cancel();
    }
    if (_one == _One.pending) {
      if (!_moved || !_swipeAllowed) return;
      _decideOne(start, d);
      if (_one == _One.pending) return;
    }
    switch (_one) {
      case _One.brightness:
      case _One.volume:
        final step = -(local.dy - _lastVerticalY) / verticalRangeDp;
        _lastVerticalY = local.dy;
        if (_one == _One.brightness) {
          callbacks.onBrightness?.call(step);
        } else {
          callbacks.onVolume?.call(step);
        }
        break;
      case _One.seek:
        final secs =
            (d.dx / seekWidthDp * secondsPerSeekWidth).round();
        callbacks.onSeekUpdate?.call(secs);
        break;
      case _One.subtitleMove:
        final step = (local.dy - _lastVerticalY) /
            (size.height <= 0 ? 1 : size.height);
        _lastVerticalY = local.dy;
        callbacks.onSubtitleMove?.call(step);
        break;
      case _One.subtitleSeek:
        final steps = (d.dx / subtitleStepDp).truncate();
        while (_lastSubtitleSteps < steps) {
          _lastSubtitleSteps++;
          callbacks.onSubtitleSeek?.call(1);
        }
        while (_lastSubtitleSteps > steps) {
          _lastSubtitleSteps--;
          callbacks.onSubtitleSeek?.call(-1);
        }
        break;
      case _One.pending:
      case _One.longPress:
      case _One.none:
        break;
    }
  }

  void _decideOne(Offset start, Offset d) {
    final ax = d.dx.abs(), ay = d.dy.abs();
    final vertical = ay > ax * directionRatio;
    final horizontal = ax > ay * directionRatio;
    if (!vertical && !horizontal) return; // not clear yet
    _cancelPendingTap();
    _endStack();
    final band = subtitleBand;
    if (switches.subtitles && band != null && band.contains(start)) {
      if (vertical && callbacks.onSubtitleMove != null) {
        _one = _One.subtitleMove;
        _lastVerticalY = start.dy + d.dy;
        callbacks.onSubtitleMove?.call(d.dy / size.height);
        return;
      }
      if (horizontal && callbacks.onSubtitleSeek != null) {
        _one = _One.subtitleSeek;
        _lastSubtitleSteps = 0;
        return;
      }
    }
    if (vertical) {
      final left = start.dx < size.width / 2;
      final on = left ? switches.brightness : switches.volume;
      final cb = left ? callbacks.onBrightness : callbacks.onVolume;
      if (!on || cb == null) {
        _one = _One.none;
        return;
      }
      _one = left ? _One.brightness : _One.volume;
      // Count the travel that decided the direction too, so the value
      // moves from the first contact as the finger does.
      _lastVerticalY = start.dy;
    } else {
      if (!switches.seek || callbacks.onSeekStart == null) {
        _one = _One.none;
        return;
      }
      _one = _One.seek;
      callbacks.onSeekStart?.call();
    }
  }

  void _upOne(Offset local) {
    _longPressTimer?.cancel();
    switch (_one) {
      case _One.longPress:
        callbacks.onLongPressEnd?.call();
        break;
      case _One.seek:
        callbacks.onSeekEnd?.call();
        break;
      case _One.brightness:
      case _One.volume:
        callbacks.onVerticalEnd?.call();
        break;
      case _One.subtitleMove:
      case _One.subtitleSeek:
        callbacks.onSubtitleEnd?.call();
        break;
      case _One.pending:
        if (!_moved) _onTapUp(_down.values.first);
        break;
      case _One.none:
        break;
    }
    _one = _One.pending;
  }

  // ── taps ────────────────────────────────────────────────────────────

  bool get _doubleTapOn =>
      switches.doubleTap && callbacks.onDoubleTap != null;

  void _onTapUp(Offset at) {
    final now = _time;
    final zone = _zoneOf(at);

    // A run of stacked side taps is open: every tap on the same side adds
    // a step at once; a tap anywhere else ends the run and counts afresh.
    if (_stackZone != null &&
        _stackLastAt != null &&
        now - _stackLastAt! <= stackWindow) {
      if (zone == _stackZone) {
        _stackCount++;
        _stackLastAt = now;
        callbacks.onDoubleTap?.call(zone, _stackCount);
        return;
      }
      _endStack();
    } else {
      _endStack();
    }

    if (!_doubleTapOn) {
      callbacks.onTap?.call();
      return;
    }

    final prev = _pendingTapAt;
    final prevAt = _pendingTapUpAt;
    if (prev != null &&
        prevAt != null &&
        now - prevAt <= doubleTapTimeout &&
        (at - prev).distance <= doubleTapSlop) {
      _cancelPendingTap();
      callbacks.onDoubleTap?.call(zone, 1);
      if (zone != TapZone.centre) {
        _stackZone = zone;
        _stackCount = 1;
        _stackLastAt = now;
      }
      return;
    }

    _cancelPendingTap();
    _pendingTapAt = at;
    _pendingTapUpAt = now;
    _singleTapTimer = Timer(doubleTapTimeout, () {
      _pendingTapAt = null;
      _pendingTapUpAt = null;
      callbacks.onTap?.call();
    });
  }

  void _cancelPendingTap() {
    _singleTapTimer?.cancel();
    _singleTapTimer = null;
    _pendingTapAt = null;
    _pendingTapUpAt = null;
  }

  void _endStack() {
    _stackZone = null;
    _stackCount = 0;
    _stackLastAt = null;
  }

  // ── two fingers ─────────────────────────────────────────────────────

  Offset get _mid {
    final p = _now.values.toList();
    return (p[0] + p[1]) / 2;
  }

  double get _spacing {
    final p = _now.values.toList();
    return (p[0] - p[1]).distance;
  }

  void _beginTwo() {
    _longPressTimer?.cancel();
    _cancelPendingTap();
    _endStack();
    // A one-finger gesture already under way ends here, cleanly.
    _finishOne();
    _two = _Two.pending;
    _twoSpacing0 = _spacing;
    _twoLastSpacing = _twoSpacing0;
    _twoMid0 = _mid;
    _twoLastMid = _twoMid0;
    final band = subtitleBand;
    _twoOnSubtitle =
        switches.subtitles && band != null && band.contains(_twoMid0);
    _lastSpeedSteps = 0;
  }

  void _moveTwo() {
    final spacing = _spacing;
    final mid = _mid;
    if (_two == _Two.pending) {
      final spread = (spacing - _twoSpacing0).abs();
      final travel = mid - _twoMid0;
      if (spread > twoFingerSlop) {
        if (_twoOnSubtitle && callbacks.onSubtitleScale != null) {
          _two = _Two.subtitlePinch;
        } else if (switches.pinch && callbacks.onPinch != null) {
          _two = _Two.pinch;
        } else {
          _two = _Two.none;
        }
      } else if (travel.dy.abs() > twoFingerSlop &&
          travel.dy.abs() > travel.dx.abs() * directionRatio &&
          _bothMovedSameWayVertically()) {
        if (switches.twoFingerSpeed && callbacks.onSpeedStart != null) {
          _two = _Two.speed;
          callbacks.onSpeedStart?.call();
        } else {
          _two = _Two.none;
        }
      } else {
        return;
      }
      _twoLastSpacing = spacing;
      _twoLastMid = mid;
    }
    switch (_two) {
      case _Two.pinch:
        if (_twoLastSpacing > 0) {
          callbacks.onPinch?.call(spacing / _twoLastSpacing, mid);
        }
        if (switches.pan) callbacks.onPan?.call(mid - _twoLastMid);
        break;
      case _Two.subtitlePinch:
        if (_twoLastSpacing > 0) {
          callbacks.onSubtitleScale?.call(spacing / _twoLastSpacing);
        }
        break;
      case _Two.speed:
        final steps = (-(mid.dy - _twoMid0.dy) / speedStepDp).truncate();
        if (steps != _lastSpeedSteps) {
          _lastSpeedSteps = steps;
          callbacks.onSpeedSteps?.call(steps);
        }
        break;
      case _Two.pending:
      case _Two.none:
        break;
    }
    _twoLastSpacing = spacing;
    _twoLastMid = mid;
  }

  bool _bothMovedSameWayVertically() {
    final ids = _now.keys.toList();
    final a = _now[ids[0]]! - _down[ids[0]]!;
    final b = _now[ids[1]]! - _down[ids[1]]!;
    return a.dy.sign == b.dy.sign && a.dy.abs() > 4 && b.dy.abs() > 4;
  }

  void _endTwo() {
    switch (_two) {
      case _Two.pinch:
        callbacks.onPinchEnd?.call();
        break;
      case _Two.subtitlePinch:
        callbacks.onSubtitleEnd?.call();
        break;
      case _Two.speed:
        callbacks.onSpeedEnd?.call();
        break;
      case _Two.pending:
      case _Two.none:
        break;
    }
    _two = _Two.none;
  }

  // ── endings ─────────────────────────────────────────────────────────

  void _finishOne() {
    _longPressTimer?.cancel();
    switch (_one) {
      case _One.longPress:
        callbacks.onLongPressEnd?.call();
        break;
      case _One.seek:
        callbacks.onSeekEnd?.call();
        break;
      case _One.brightness:
      case _One.volume:
        callbacks.onVerticalEnd?.call();
        break;
      case _One.subtitleMove:
      case _One.subtitleSeek:
        callbacks.onSubtitleEnd?.call();
        break;
      case _One.pending:
      case _One.none:
        break;
    }
    _one = _One.none;
  }

  void _endAll() {
    _cancelPendingTap();
    _finishOne();
    _endTwo();
  }

  /// For the overlay to ignore a global position it does not need.
  Offset? get downGlobal => _downGlobal;
}
