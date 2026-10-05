import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/subtitle_look.dart';
import 'package:innocent/features/player/presentation/aspect_ratio_mode.dart';
import 'package:innocent/features/player/presentation/gestures/subtitle_band.dart';
import 'package:innocent/features/player/presentation/video_geometry.dart';
import 'package:innocent/features/player/presentation/widgets/gesture_overlay.dart';

class _Calls {
  final log = <String>[];
  double volume = 0, brightness = 0;
  int? seek;
}

Widget _overlay(_Calls c,
    {Rect? subtitle, EdgeInsets gestureInsets = EdgeInsets.zero}) {
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
      await tester.pumpWidget(
          _overlay(c, gestureInsets: const EdgeInsets.fromLTRB(32, 0, 32, 32)));
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

  group('subtitle placement', () {
    // A 16:9 film on a 400 x 800 portrait screen: 225 dp tall, centred.
    const view = Size(400, 800);
    final frame = Rect.fromCenter(
        center: const Offset(200, 400), width: 400, height: 225);

    test('sits on the picture, above its bottom, sized from the screen', () {
      final g = subtitleGeometry(
          view: view, picture: frame, look: const SubtitleLook());
      expect(g.bottom, lessThan(frame.bottom));
      expect(g.bottom, greaterThan(frame.center.dy));
      // Medium (18) on a phone whose short side is 400 dp: 18 x 400/360.
      expect(g.fontSize, closeTo(18 * 400 / 360, 0.01));
      final band = g.touchBand(2);
      expect(band.bottom, lessThanOrEqualTo(frame.bottom + 20));
      expect(band.left, greaterThan(frame.left));
    });

    test('moves up with sub-pos and grows with sub-scale', () {
      SubtitleGeometry at(int pos, double scale) => subtitleGeometry(
          view: view,
          picture: frame,
          look: const SubtitleLook()
              .apply('sub-pos', '$pos')
              .apply('sub-scale', '$scale'));
      expect(at(50, 1).bottom, lessThan(at(100, 1).bottom));
      expect(at(100, 2).fontSize, closeTo(at(100, 1).fontSize * 2, 0.01));
    });

    test('a picture zoomed past the screen keeps the subtitle on screen', () {
      // Crop on a landscape phone: the picture runs 120 dp past each edge.
      const land = Size(800, 400);
      final zoomed = Rect.fromCenter(
          center: const Offset(400, 200), width: 1040, height: 585);
      final g = subtitleGeometry(
          view: land, picture: zoomed, look: const SubtitleLook());
      expect(g.bottom, lessThanOrEqualTo(land.height));
      expect(g.box.left, greaterThanOrEqualTo(0));
      expect(g.box.right, lessThanOrEqualTo(land.width));
      // ...and the same size as unzoomed: zoom does not enlarge it.
      final plain = subtitleGeometry(
          view: land, picture: Offset.zero & land, look: const SubtitleLook());
      expect(g.fontSize, plain.fontSize);
    });

    test('libmpv properties become the look', () {
      final look = const SubtitleLook()
          .apply('sub-color', '#FFFFFF00')
          .apply('sub-border-size', '1.5')
          .apply('sub-back-color', '#80000000')
          .apply('sub-font', 'serif')
          .apply('sub-font-size', 'nonsense');
      expect(look.color, const Color(0xFFFFFF00));
      expect(look.borderSize, 1.5);
      expect(look.backColor, const Color(0x80000000));
      expect(look.font, 'serif');
      expect(look.fontSize, 18);
      expect(look.apply('sub-font', '/sdcard/x.ttf').font, isNull);
    });
  });

  group('screen modes (MX: Fit, Stretch, Crop, 100%, Custom)', () {
    const land = Size(800, 400); // a 2:1 phone, sideways
    const film = Size(1920, 1080); // 16:9

    double scale(AspectRatioMode m, {double custom = 1, double dpr = 2.5}) =>
        screenModeScale(
            mode: m,
            view: land,
            video: film,
            devicePixelRatio: dpr,
            customScale: custom);

    test('the cycle is MX\'s order and wraps', () {
      var m = AspectRatioMode.fit;
      final seen = <AspectRatioMode>[];
      for (var i = 0; i < 5; i++) {
        seen.add(m);
        m = m.next;
      }
      expect(seen, [
        AspectRatioMode.fit,
        AspectRatioMode.stretch,
        AspectRatioMode.crop,
        AspectRatioMode.original,
        AspectRatioMode.custom,
      ]);
      expect(m, AspectRatioMode.fit);
    });

    test('Fit shows the whole frame; Stretch fills it', () {
      expect(scale(AspectRatioMode.fit), 1);
      expect(
          pictureSize(
              mode: AspectRatioMode.fit, view: land, video: film, scale: 1),
          const Size(711.1111111111111, 400));
      expect(
          pictureSize(
              mode: AspectRatioMode.stretch, view: land, video: film, scale: 1),
          land);
    });

    test('Crop zooms until no bar is left, keeping the shape', () {
      final s = scale(AspectRatioMode.crop);
      final pic = pictureSize(
          mode: AspectRatioMode.crop, view: land, video: film, scale: s);
      expect(pic.width, closeTo(800, 0.001));
      expect(pic.height, greaterThan(400));
      expect(pic.width / pic.height, closeTo(16 / 9, 0.001));
    });

    test('100% puts one video pixel on one screen pixel', () {
      final s = scale(AspectRatioMode.original, dpr: 2.5);
      final pic = pictureSize(
          mode: AspectRatioMode.original, view: land, video: film, scale: s);
      expect(pic.width * 2.5, closeTo(1920, 0.001));
    });

    test('Custom is the pinch zoom', () {
      expect(scale(AspectRatioMode.custom, custom: 1.7), 1.7);
    });

    test('a pan never pulls a bar into view, and is zero when it fits', () {
      const view = Size(400, 800);
      expect(clampPan(const Offset(500, 0), const Size(400, 225), view),
          Offset.zero);
      expect(clampPan(const Offset(500, -900), const Size(800, 1600), view),
          const Offset(200, -400));
      expect(clampPan(const Offset(50, 20), const Size(800, 1600), view),
          const Offset(50, 20));
    });
  });
}
