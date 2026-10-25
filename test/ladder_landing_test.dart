import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/exo_engine.dart';
import 'package:innocent/features/player/presentation/ladder_preview_loader.dart';

Uint8List _jpeg(int n) => Uint8List.fromList([0xFF, 0xD8, n]);

void main() {
  group('LadderPreviewLoader', () {
    test('a fast drag fetches the first moment and the last, not each one between', () async {
      final asked = <int>[];
      final waiting = <Completer<Uint8List?>>[];
      final loader = LadderPreviewLoader((at) {
        asked.add(at.inSeconds);
        final c = Completer<Uint8List?>();
        waiting.add(c);
        return c.future;
      });
      final shown = <int>[];
      void show(Uint8List b) => shown.add(b[2]);

      for (final s in [100, 110, 120, 130, 140]) {
        loader.request(s, show);
      }
      expect(asked, [100]);
      waiting[0].complete(_jpeg(1));
      await Future<void>.delayed(Duration.zero);
      // The one on its way is shown, then the newest is fetched.
      expect(shown, [1]);
      expect(asked, [100, 140]);
      waiting[1].complete(_jpeg(2));
      await Future<void>.delayed(Duration.zero);
      expect(shown, [1, 2]);
      expect(asked, [100, 140]);
    });

    test('the same two seconds again are given again, not fetched', () async {
      var fetches = 0;
      final loader = LadderPreviewLoader((at) async {
        fetches++;
        return _jpeg(7);
      });
      final shown = <int>[];
      loader.request(50, (b) => shown.add(b[2]));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // A new drag where the last one ended: 51 s is the same fragment.
      loader.request(51, (b) => shown.add(b[2]));
      await Future<void>.delayed(Duration.zero);
      expect(fetches, 1);
      expect(shown, [7, 7]);
    });

    test('a moment asked for while busy, in the same fragment, is not fetched twice', () async {
      final asked = <int>[];
      final c = Completer<Uint8List?>();
      final loader = LadderPreviewLoader((at) {
        asked.add(at.inSeconds);
        return c.future;
      });
      loader.request(20, (_) {});
      loader.request(21, (_) {});
      c.complete(_jpeg(1));
      await Future<void>.delayed(Duration.zero);
      expect(asked, [20]);
    });

    test('a failed fetch frees the line for the next', () async {
      final asked = <int>[];
      var first = true;
      final loader = LadderPreviewLoader((at) {
        asked.add(at.inSeconds);
        if (first) {
          first = false;
          return Future<Uint8List?>.error(StateError('no line'));
        }
        return Future<Uint8List?>.value(_jpeg(3));
      });
      final shown = <int>[];
      loader.request(10, (b) => shown.add(b[2]));
      loader.request(30, (b) => shown.add(b[2]));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(asked, [10, 30]);
      expect(shown, [3]);
    });

    test('nothing is shown after dispose', () async {
      final c = Completer<Uint8List?>();
      final loader = LadderPreviewLoader((_) => c.future);
      final shown = <int>[];
      loader.request(10, (b) => shown.add(b[2]));
      loader.dispose();
      c.complete(_jpeg(1));
      await Future<void>.delayed(Duration.zero);
      expect(shown, isEmpty);
    });
  });

  group('ExoEngine landing picture', () {
    testWidgets('held over the old frame until the jump draws its own', (tester) async {
      final e = ExoEngine.forTest();
      unawaited(e.seek(const Duration(minutes: 5), fast: true, picture: _jpeg(1)));
      // Not at once: a jump from memory is quicker than the picture.
      expect(e.landing.value, isNull);
      await tester.pump(ExoEngine.landingAfter + const Duration(milliseconds: 10));
      expect(e.landing.value, isNotNull);
      expect(e.lastLanding, isNull);
      await tester.pump(const Duration(milliseconds: 300));
      e.debugEvent(<Object?, Object?>{'e': 'first'});
      expect(e.landing.value, isNull);
      expect(e.lastLanding, endsWith('first frame'));
    });

    testWidgets('not shown when the frame comes first', (tester) async {
      final e = ExoEngine.forTest();
      unawaited(e.seek(const Duration(minutes: 5), fast: true, picture: _jpeg(1)));
      await tester.pump(const Duration(milliseconds: 40));
      e.debugEvent(<Object?, Object?>{'e': 'first'});
      await tester.pump(ExoEngine.landingAfter * 2);
      expect(e.landing.value, isNull);
      expect(e.lastLanding, 'not needed');
    });

    testWidgets('gone after its time even if no frame comes', (tester) async {
      final e = ExoEngine.forTest();
      unawaited(e.seek(const Duration(minutes: 5), fast: true, picture: _jpeg(1)));
      await tester.pump(ExoEngine.landingAfter + const Duration(milliseconds: 10));
      expect(e.landing.value, isNotNull);
      await tester.pump(ExoEngine.landingAtMost);
      expect(e.landing.value, isNull);
      expect(e.lastLanding, endsWith('timed out'));
    });

    testWidgets('drawn in the film\'s own box, over the texture, and taken away', (tester) async {
      final e = ExoEngine.forTest();
      e.debugEvent(<Object?, Object?>{'e': 'size', 'w': 1280, 'h': 720});
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: SizedBox(width: 320, height: 180, child: ExoVideo(engine: e))),
      ));
      expect(find.byType(Texture), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      unawaited(e.seek(const Duration(minutes: 5), fast: true, picture: _jpeg(1)));
      await tester.pump(ExoEngine.landingAfter + const Duration(milliseconds: 10));
      final picture = find.byType(Image);
      expect(picture, findsOneWidget);
      // The same size as the texture: it takes the film's fit and zoom.
      expect(tester.getSize(picture), tester.getSize(find.byType(Texture)));
      e.debugEvent(<Object?, Object?>{'e': 'first'});
      await tester.pump();
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('a jump with no picture, or an error, leaves nothing up', (tester) async {
      final e = ExoEngine.forTest();
      unawaited(e.seek(const Duration(minutes: 5), fast: true, picture: _jpeg(1)));
      await tester.pump(ExoEngine.landingAfter + const Duration(milliseconds: 10));
      unawaited(e.seek(const Duration(minutes: 9), fast: true));
      expect(e.landing.value, isNull);
      expect(e.lastLanding, 'no picture');
      unawaited(e.seek(const Duration(minutes: 2), fast: true, picture: _jpeg(2)));
      await tester.pump(ExoEngine.landingAfter + const Duration(milliseconds: 10));
      e.debugEvent(<Object?, Object?>{'e': 'error', 'code': 'x', 'msg': 'y'});
      expect(e.landing.value, isNull);
      await tester.pump(ExoEngine.landingAtMost);
    });
  });
}
