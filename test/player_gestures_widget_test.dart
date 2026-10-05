import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/gestures/subtitle_band.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/widgets/gesture_overlay.dart';

class _Calls {
  final log = <String>[];
  double volume = 0, brightness = 0;
  int? seek;
}

Widget _overlay(_Calls c, {Rect? subtitle, EdgeInsets gestureInsets = EdgeInsets.zero}) {
  return MediaQuery(
    data: MediaQueryData(
      size: const Size(400, 800),
      systemGestureInsets: gestureInsets,
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: GestureOverlay(
        onTap: () => c.log.add('tap'),
        onDoubleTapRewind: () => c.log.add('rewind'),
        onDoubleTapForward: () => c.log.add('forward'),
        onDoubleTapCenter: () => c.log.add('playpause'),
        onDoubleTapStacked: (f, n) => c.log.add('${f ? 'fwd' : 'back'} $n'),
        onBrightnessDelta: (d) => c.brightness += d,
        onVolumeDelta: (d) => c.volume += d,
        onSeekStart: () => c.log.add('seek start'),
        onSeekUpdate: (s) => c.seek = s,
        onSeekEnd: () => c.log.add('seek end'),
        onLongPressStart: () => c.log.add('long'),
        onLongPressEnd: () => c.log.add('long end'),
        onSubtitleMove: (_) => c.log.add('sub move'),
        onSubtitleEnd: () => c.log.add('sub end'),
        subtitleBand: (_) => subtitle,
        duration: const Duration(hours: 1),
      ),
    ),
  );
}

/// A 400 x 800 dp phone for the duration of one test.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('the overlay, driven by real touches', () {
    testWidgets('a drag across seeks; a drag up on the right is volume',
        (tester) async {
      _phone(tester);
      final c = _Calls();
      await tester.pumpWidget(_overlay(c));
      await tester.dragFrom(const Offset(100, 400), const Offset(200, 0));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.log, ['seek start', 'seek end']);
      expect(c.seek, greaterThan(15));
      await tester.dragFrom(const Offset(300, 500), const Offset(0, -150));
      expect(c.volume, greaterThan(0.25));
      expect(c.brightness, 0);
    });

    testWidgets('double taps on the right stack', (tester) async {
      _phone(tester);
      final c = _Calls();
      await tester.pumpWidget(_overlay(c));
      for (var i = 0; i < 4; i++) {
        await tester.tapAt(const Offset(370, 400));
        await tester.pump(const Duration(milliseconds: 120));
      }
      await tester.pump(const Duration(seconds: 1));
      expect(c.log, ['fwd 1', 'fwd 2', 'fwd 3']);
    });

    testWidgets('a swipe from the Back-gesture edge is left to Android',
        (tester) async {
      _phone(tester);
      final c = _Calls();
      await tester.pumpWidget(_overlay(c,
          gestureInsets: const EdgeInsets.fromLTRB(32, 0, 32, 32)));
      await tester.dragFrom(const Offset(10, 400), const Offset(200, 0));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.log, isEmpty);
      expect(c.seek, isNull);
    });

    testWidgets('on a showing subtitle, a vertical drag moves the subtitle',
        (tester) async {
      _phone(tester);
      final c = _Calls();
      await tester.pumpWidget(
          _overlay(c, subtitle: const Rect.fromLTRB(40, 640, 360, 720)));
      await tester.dragFrom(const Offset(300, 680), const Offset(0, -80));
      expect(c.log.first, 'sub move');
      expect(c.log.last, 'sub end');
      expect(c.log.toSet(), {'sub move', 'sub end'});
      expect(c.volume, 0);
    });
  });

  group('subtitle band', () {
    test('sits inside the letterboxed frame, above its bottom', () {
      // A 16:9 film on a 400 x 800 portrait screen: 225 dp tall, centred.
      final band = subtitleBandFor(
        player: const Size(400, 800),
        video: const Size(1920, 1080),
        fit: BoxFit.contain,
        positionPct: 100,
        scale: 1,
        lines: 2,
      );
      const frameTop = (800 - 225) / 2, frameBottom = frameTop + 225;
      expect(band.bottom, lessThanOrEqualTo(frameBottom + 20));
      expect(band.top, greaterThan(frameTop));
      expect(band.left, closeTo(40, 0.5));
      expect(band.right, closeTo(360, 0.5));
    });

    test('moves up with sub-pos and grows with sub-scale', () {
      Rect at(int pos, double scale) => subtitleBandFor(
            player: const Size(800, 400),
            video: null,
            fit: BoxFit.contain,
            positionPct: pos,
            scale: scale,
            lines: 1,
          );
      expect(at(50, 1).bottom, lessThan(at(100, 1).bottom));
      expect(at(100, 2).height, greaterThan(at(100, 1).height));
    });
  });

  group('pan while zoomed', () {
    test('never drags an edge into view, and is zero at 1x', () {
      const view = Size(400, 800);
      expect(clampVideoOffset(const Offset(500, 0), 1.0, view), Offset.zero);
      // At 2x the picture is 800 x 1600: 200 dp spare on each side.
      expect(clampVideoOffset(const Offset(500, -900), 2.0, view),
          const Offset(200, -400));
      expect(clampVideoOffset(const Offset(50, 20), 2.0, view),
          const Offset(50, 20));
    });
  });
}
