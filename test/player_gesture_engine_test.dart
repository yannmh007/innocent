import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/gestures/player_gesture_engine.dart';

/// Records what the engine reported, in order.
class _Log {
  final events = <String>[];
  double brightness = 0, volume = 0, subtitleMove = 0, scale = 1, subScale = 1;
  Offset pan = Offset.zero;
  int? seekSeconds, speedSteps;
  int subtitleSeek = 0;

  GestureCallbacks get callbacks => GestureCallbacks(
        onTap: () => events.add('tap'),
        onDoubleTap: (z, n) => events.add('double ${z.name} $n'),
        onLongPressStart: () => events.add('long start'),
        onLongPressMove: (_) => events.add('long move'),
        onLongPressEnd: () => events.add('long end'),
        onBrightness: (d) => brightness += d,
        onVolume: (d) => volume += d,
        onVerticalEnd: () => events.add('vertical end'),
        onSeekStart: () => events.add('seek start'),
        onSeekUpdate: (s) => seekSeconds = s,
        onSeekEnd: () => events.add('seek end'),
        onSpeedStart: () => events.add('speed start'),
        onSpeedSteps: (n) => speedSteps = n,
        onSpeedEnd: () => events.add('speed end'),
        onPinch: (d, _) => scale *= d,
        onPan: (d) => pan += d,
        onPinchEnd: () => events.add('pinch end'),
        onSubtitleMove: (d) => subtitleMove += d,
        onSubtitleScale: (d) => subScale *= d,
        onSubtitleSeek: (dir) => subtitleSeek += dir,
        onSubtitleEnd: () => events.add('subtitle end'),
      );
}

/// A phone in portrait: 412 x 915 dp.
PlayerGestureEngine _engine(_Log log, {Size size = const Size(412, 915)}) {
  return PlayerGestureEngine(callbacks: log.callbacks)
    ..size = size
    ..duration = const Duration(hours: 2);
}

const _ms = Duration(milliseconds: 1);

/// One finger, down at [from], moved in [steps] to [to], then up.
void _drag(PlayerGestureEngine e, Offset from, Offset to,
    {int id = 1, Duration at = Duration.zero, int steps = 10, bool up = true}) {
  e.pointerDown(id, from, at);
  for (var i = 1; i <= steps; i++) {
    e.pointerMove(id, Offset.lerp(from, to, i / steps)!, at + _ms * (i * 16));
  }
  if (up) e.pointerUp(id, to, at + _ms * (steps * 16 + 10));
}

void _tap(PlayerGestureEngine e, Offset at, Duration time, {int id = 1}) {
  e.pointerDown(id, at, time);
  e.pointerUp(id, at, time + _ms * 60);
}

void main() {
  group('taps', () {
    testWidgets('a single tap waits out the double-tap window, then fires',
        (tester) async {
      final log = _Log();
      final e = _engine(log);
      _tap(e, const Offset(200, 400), Duration.zero);
      expect(log.events, isEmpty);
      await tester.pump(const Duration(milliseconds: 310));
      expect(log.events, ['tap']);
      e.dispose();
    });

    testWidgets('with double tap off, a tap fires at once', (tester) async {
      final log = _Log();
      final e = _engine(log)..switches = const GestureSwitches(doubleTap: false);
      _tap(e, const Offset(200, 400), Duration.zero);
      expect(log.events, ['tap']);
      e.dispose();
    });

    testWidgets('double taps on one side stack; the other side starts afresh',
        (tester) async {
      final log = _Log();
      final e = _engine(log);
      const right = Offset(380, 400), left = Offset(30, 400);
      _tap(e, right, Duration.zero);
      _tap(e, right, const Duration(milliseconds: 200));
      expect(log.events, ['double right 1']);
      // Further single taps on the right add a step each, at once.
      _tap(e, right, const Duration(milliseconds: 600));
      _tap(e, right, const Duration(milliseconds: 1000));
      expect(log.events, ['double right 1', 'double right 2', 'double right 3']);
      // The left side ends the run: it is a fresh tap, not a step.
      _tap(e, left, const Duration(milliseconds: 1300));
      await tester.pump(const Duration(milliseconds: 310));
      expect(log.events.last, 'tap');
      e.dispose();
    });

    testWidgets('the run closes after 0.6 s of quiet', (tester) async {
      final log = _Log();
      final e = _engine(log);
      const right = Offset(380, 400);
      _tap(e, right, Duration.zero);
      _tap(e, right, const Duration(milliseconds: 200));
      _tap(e, right, const Duration(milliseconds: 1200));
      await tester.pump(const Duration(milliseconds: 310));
      expect(log.events, ['double right 1', 'tap']);
      e.dispose();
    });

    testWidgets('a centre double tap plays / pauses and does not stack',
        (tester) async {
      final log = _Log();
      final e = _engine(log);
      const centre = Offset(206, 400);
      _tap(e, centre, Duration.zero);
      _tap(e, centre, const Duration(milliseconds: 200));
      _tap(e, centre, const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 310));
      expect(log.events, ['double centre 1', 'tap']);
      e.dispose();
    });
  });

  group('long press', () {
    testWidgets('holding starts it; moving reports; lifting ends; no tap',
        (tester) async {
      final log = _Log();
      final e = _engine(log);
      e.pointerDown(1, const Offset(200, 400), Duration.zero);
      await tester.pump(const Duration(milliseconds: 520));
      e.pointerMove(1, const Offset(260, 400), const Duration(milliseconds: 600));
      e.pointerUp(1, const Offset(260, 400), const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 400));
      expect(log.events, ['long start', 'long move', 'long end']);
      e.dispose();
    });

    testWidgets('switched off, a long hold is a tap', (tester) async {
      final log = _Log();
      final e = _engine(log)..switches = const GestureSwitches(longPress: false);
      e.pointerDown(1, const Offset(200, 400), Duration.zero);
      await tester.pump(const Duration(milliseconds: 700));
      e.pointerUp(1, const Offset(200, 400), const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 310));
      expect(log.events, ['tap']);
      e.dispose();
    });
  });

  group('one-finger swipes', () {
    testWidgets('left side up raises brightness by travel / range',
        (tester) async {
      final log = _Log();
      final e = _engine(log);
      _drag(e, const Offset(100, 600), const Offset(100, 400));
      // 200 dp of a 480 dp range (0.6 x 915 = 549, capped at 480).
      expect(log.brightness, closeTo(200 / 480, 0.001));
      expect(log.volume, 0);
      expect(log.events, ['vertical end']);
      await tester.pump(const Duration(milliseconds: 400));
      expect(log.events, ['vertical end']); // and no tap
      e.dispose();
    });

    testWidgets('right side down lowers volume', (tester) async {
      final log = _Log();
      final e = _engine(log);
      _drag(e, const Offset(320, 300), const Offset(320, 420));
      expect(log.volume, closeTo(-120 / 480, 0.001));
      e.dispose();
    });

    testWidgets('a diagonal movement waits until the direction is clear',
        (tester) async {
      final log = _Log();
      final e = _engine(log);
      // 20 across, 22 down: past the slop but neither direction is 1.5x.
      _drag(e, const Offset(100, 400), const Offset(120, 422), up: false);
      expect(log.events, isEmpty);
      expect(log.brightness, 0);
      e.pointerMove(1, const Offset(122, 480), const Duration(milliseconds: 400));
      expect(log.brightness, lessThan(0));
      e.dispose();
    });

    testWidgets('horizontal swipe seeks 90 s per width on a phone',
        (tester) async {
      final log = _Log();
      final e = _engine(log);
      _drag(e, const Offset(50, 400), const Offset(256, 400));
      expect(log.events, ['seek start', 'seek end']);
      expect(log.seekSeconds, (206 / 412 * 90).round());
      e.dispose();
    });

    testWidgets('a 30 s clip seeks at most its own length per width',
        (tester) async {
      final log = _Log();
      final e = _engine(log)..duration = const Duration(seconds: 30);
      _drag(e, const Offset(0 + 1, 400), const Offset(412, 400));
      expect(log.seekSeconds, closeTo(30, 1));
      e.dispose();
    });

    testWidgets('a tablet feels like a phone: same dp, same change',
        (tester) async {
      final log = _Log();
      final e = _engine(log, size: const Size(1280, 800));
      expect(e.verticalRangeDp, 480);
      expect(e.seekWidthDp, 600);
      _drag(e, const Offset(300, 400), const Offset(600, 400));
      expect(log.seekSeconds, (300 / 600 * 90).round());
      e.dispose();
    });

    testWidgets('no swipe starts inside the system-gesture zones; taps do',
        (tester) async {
      final log = _Log();
      final e = _engine(log)
        ..noSwipeInsets = const EdgeInsets.fromLTRB(30, 24, 30, 32);
      // From the left edge inward: that is Android's Back, not a seek.
      _drag(e, const Offset(10, 400), const Offset(200, 400));
      // From the top down: the notification shade, not brightness.
      _drag(e, const Offset(100, 10), const Offset(100, 300), id: 2);
      expect(log.events, isEmpty);
      expect(log.brightness, 0);
      _tap(e, const Offset(10, 400), const Duration(seconds: 2), id: 3);
      await tester.pump(const Duration(milliseconds: 310));
      expect(log.events, ['tap']);
      e.dispose();
    });

    testWidgets('brightness switched off does not fall through to volume',
        (tester) async {
      final log = _Log();
      final e = _engine(log)
        ..switches = const GestureSwitches(brightness: false);
      _drag(e, const Offset(100, 600), const Offset(100, 400));
      expect(log.brightness, 0);
      expect(log.volume, 0);
      e.dispose();
    });
  });

  group('two fingers', () {
    testWidgets('moving up together raises the speed one step per 24 dp',
        (tester) async {
      final log = _Log();
      final e = _engine(log);
      e.pointerDown(1, const Offset(150, 600), Duration.zero);
      e.pointerDown(2, const Offset(250, 600), Duration.zero);
      for (var i = 1; i <= 10; i++) {
        final dy = -10.0 * i;
        e.pointerMove(1, Offset(150, 600 + dy), _ms * (i * 16));
        e.pointerMove(2, Offset(250, 600 + dy), _ms * (i * 16 + 1));
      }
      e.pointerUp(1, const Offset(150, 500), const Duration(seconds: 1));
      e.pointerUp(2, const Offset(250, 500), const Duration(seconds: 1));
      expect(log.events, ['speed start', 'speed end']);
      expect(log.speedSteps, 4); // 100 dp / 24
      expect(log.scale, 1);
      e.dispose();
    });

    testWidgets('spreading zooms, and the midpoint pans', (tester) async {
      final log = _Log();
      final e = _engine(log);
      e.pointerDown(1, const Offset(150, 400), Duration.zero);
      e.pointerDown(2, const Offset(250, 400), Duration.zero);
      for (var i = 1; i <= 10; i++) {
        e.pointerMove(1, Offset(150 - 5.0 * i, 400 + 2.0 * i), _ms * (i * 16));
        e.pointerMove(2, Offset(250 + 5.0 * i, 400 + 2.0 * i), _ms * (i * 16 + 1));
      }
      e.pointerUp(1, const Offset(100, 420), const Duration(seconds: 1));
      e.pointerUp(2, const Offset(300, 420), const Duration(seconds: 1));
      expect(log.scale, greaterThan(1.5));
      expect(log.pan.dy, greaterThan(0));
      expect(log.events, ['pinch end']);
      e.dispose();
    });

    testWidgets('a second finger ends a seek; the finger left behind is inert',
        (tester) async {
      final log = _Log();
      final e = _engine(log);
      _drag(e, const Offset(50, 400), const Offset(150, 400), up: false);
      expect(log.events, ['seek start']);
      e.pointerDown(2, const Offset(300, 400), const Duration(seconds: 1));
      expect(log.events, ['seek start', 'seek end']);
      e.pointerUp(2, const Offset(300, 400), const Duration(seconds: 2));
      final before = log.seekSeconds;
      e.pointerMove(1, const Offset(400, 400), const Duration(seconds: 3));
      e.pointerUp(1, const Offset(400, 400), const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 400));
      expect(log.seekSeconds, before);
      expect(log.events, ['seek start', 'seek end']);
      e.dispose();
    });
  });

  group('subtitles', () {
    PlayerGestureEngine withSubtitle(_Log log) =>
        _engine(log)..subtitleBand = const Rect.fromLTRB(40, 700, 372, 780);

    testWidgets('a vertical drag on the subtitle moves it, not the volume',
        (tester) async {
      final log = _Log();
      final e = withSubtitle(log);
      _drag(e, const Offset(300, 740), const Offset(300, 640));
      expect(log.subtitleMove, closeTo(-100 / 915, 0.002));
      expect(log.volume, 0);
      expect(log.events, ['subtitle end']);
      e.dispose();
    });

    testWidgets('a horizontal swipe on it steps a line per 64 dp',
        (tester) async {
      final log = _Log();
      final e = withSubtitle(log);
      _drag(e, const Offset(100, 740), const Offset(250, 740));
      expect(log.subtitleSeek, 2);
      expect(log.seekSeconds, isNull);
      e.dispose();
    });

    testWidgets('a pinch on it sizes the subtitle, not the video',
        (tester) async {
      final log = _Log();
      final e = withSubtitle(log);
      e.pointerDown(1, const Offset(180, 740), Duration.zero);
      e.pointerDown(2, const Offset(230, 740), Duration.zero);
      for (var i = 1; i <= 8; i++) {
        e.pointerMove(1, Offset(180 - 6.0 * i, 740), _ms * (i * 16));
        e.pointerMove(2, Offset(230 + 6.0 * i, 740), _ms * (i * 16 + 1));
      }
      e.pointerUp(1, const Offset(132, 740), const Duration(seconds: 1));
      e.pointerUp(2, const Offset(278, 740), const Duration(seconds: 1));
      expect(log.subScale, greaterThan(1.5));
      expect(log.scale, 1);
      e.dispose();
    });

    testWidgets('outside the band, the same drag is the volume',
        (tester) async {
      final log = _Log();
      final e = withSubtitle(log);
      _drag(e, const Offset(300, 500), const Offset(300, 400));
      expect(log.volume, greaterThan(0));
      expect(log.subtitleMove, 0);
      e.dispose();
    });
  });
}
