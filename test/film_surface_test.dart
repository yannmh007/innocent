// P1 in production (28 Nov 2026, the owner's choice): a catalogue film
// (ExoPlayer) drawn on Android's own SurfaceView under Flutter's
// see-through surface, the dialogs' glass a tint alone. What Flutter's side
// must do for it, without a phone: when the film may go there, what the
// player's picture draws while it is there (nothing but the landing
// picture; the in-app picture-in-picture window black), the glass without
// a blur, Night mode as a black layer.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/exo_engine.dart';
import 'package:innocent/features/player/presentation/film_surface.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/widgets/player_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/player_harness.dart';

/// A 1x1 PNG, the landing picture of a far jump.
final Uint8List _png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Widget _box(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(width: 400, height: 300, child: child),
    );

void main() {
  group('filmSurfaceAllowed', () {
    bool allowed({
      bool videoShown = true,
      bool sizeKnown = true,
      bool mirror = false,
      bool flip = false,
      bool colourNeutral = true,
      bool routeIn = true,
    }) =>
        filmSurfaceAllowed(
          videoShown: videoShown,
          sizeKnown: sizeKnown,
          mirror: mirror,
          flip: flip,
          colourNeutral: colourNeutral,
          routeIn: routeIn,
        );

    test('a plain film playing goes on its own surface', () {
      expect(allowed(), isTrue);
    });

    test('what needs the picture inside Flutter keeps it on the texture', () {
      expect(allowed(mirror: true), isFalse, reason: 'mirror');
      expect(allowed(flip: true), isFalse, reason: 'vertical flip');
      expect(allowed(colourNeutral: false), isFalse,
          reason: "Display's colour filters (the owner's word)");
    });

    test('nowhere to place it, or a route moving over it: the texture', () {
      expect(allowed(sizeKnown: false), isFalse);
      expect(allowed(videoShown: false), isFalse);
      expect(allowed(routeIn: false), isFalse);
    });
  });

  test("Night mode's black layer is the old colour matrix's 40 %", () {
    final a = ((nightShadeArgb >> 24) & 0xFF) / 255;
    // A white pixel under black at alpha a reads 1 - a.
    expect(1 - a, closeTo(0.4, 0.001));
    expect(nightShadeArgb & 0xFFFFFF, 0, reason: 'black, not a tint');
  });

  group('ExoVideo', () {
    late ExoEngine engine;
    setUp(() {
      engine = ExoEngine.forTest();
      engine.debugEvent(<Object?, Object?>{'e': 'size', 'w': 1920, 'h': 1080});
    });

    testWidgets('on the texture: the texture, on black', (tester) async {
      await tester.pumpWidget(_box(ExoVideo(engine: engine, filmHost: true)));
      expect(find.byType(Texture), findsOneWidget);
    });

    testWidgets(
        'the film on its own surface: the player draws nothing over it',
        (tester) async {
      await tester.pumpWidget(_box(ExoVideo(engine: engine, filmHost: true)));
      engine.debugEvent(<Object?, Object?>{'e': 'film', 'on': true});
      await tester.pump();
      expect(engine.onSurface.value, isTrue);
      expect(find.byType(Texture), findsNothing);
      expect(
          find.byWidgetPredicate((w) =>
              w is ColoredBox && w.color == const Color(0xFF000000)),
          findsNothing,
          reason: 'a black box would hide the film under Flutter');
      // Back on the texture once its first frame is there.
      engine.debugEvent(<Object?, Object?>{'e': 'film', 'on': false});
      await tester.pump();
      expect(find.byType(Texture), findsOneWidget);
    });

    testWidgets("a far jump's landing picture still shows over the film",
        (tester) async {
      await tester.pumpWidget(_box(ExoVideo(engine: engine, filmHost: true)));
      engine.debugEvent(<Object?, Object?>{'e': 'film', 'on': true});
      engine.landing.value = _png;
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
    });

    testWidgets(
        'the in-app picture-in-picture window is black while the film is on '
        "the player's surface (the texture holds an old frame)",
        (tester) async {
      await tester.pumpWidget(_box(ExoVideo(engine: engine)));
      engine.debugEvent(<Object?, Object?>{'e': 'film', 'on': true});
      await tester.pump();
      expect(find.byType(Texture), findsNothing);
      expect(
          find.byWidgetPredicate((w) =>
              w is ColoredBox && w.color == const Color(0xFF000000)),
          findsOneWidget);
    });

    testWidgets("the viewer's Aspect ratio shapes the texture too",
        (tester) async {
      await tester.pumpWidget(
          _box(ExoVideo(engine: engine, aspect: 4 / 3, filmHost: true)));
      final box = tester.renderObject<RenderBox>(find.byType(Texture));
      expect(box.size.width / box.size.height, closeTo(4 / 3, 0.001),
          reason: 'before 28 Nov the film kept 16:9 while its subtitles '
              'moved to the 4:3 picture');
    });

    testWidgets('a note from the phone changes nothing', (tester) async {
      await tester.pumpWidget(_box(ExoVideo(engine: engine, filmHost: true)));
      engine.debugEvent(
          <Object?, Object?>{'e': 'film', 'note': 'paused switch, nudged'});
      await tester.pump();
      expect(engine.onSurface.value, isFalse);
      expect(find.byType(Texture), findsOneWidget);
    });
  });

  group('ExoEngine.useSurface', () {
    const channel = MethodChannel('innocent/exo');
    late List<String> calls;

    setUp(() {
      calls = <String>[];
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add('${call.method} ${(call.arguments as Map)['on'] ?? ''}'.trim());
        return true;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    test('asks once, and the move lands with the first frame', () async {
      final e = ExoEngine.forTest();
      expect(await e.useSurface(true), isTrue);
      expect(await e.useSurface(true), isTrue);
      expect(calls, ['filmSurface true'], reason: 'asked once');
      e.debugEvent(<Object?, Object?>{'e': 'film', 'on': true});
      expect(e.onSurface.value, isTrue);
    });

    test('the phone taking the film back lets the player ask again', () async {
      final e = ExoEngine.forTest();
      await e.useSurface(true);
      e.debugEvent(<Object?, Object?>{'e': 'film', 'on': true});
      // A new Activity, or FLAG_SECURE changed: Kotlin dropped the view.
      e.debugEvent(<Object?, Object?>{'e': 'film', 'on': false});
      expect(e.onSurface.value, isFalse);
      expect(e.surfaceAsked, isFalse);
      await e.useSurface(true);
      expect(calls, ['filmSurface true', 'filmSurface true']);
    });

    testWidgets(
        'a playing film whose surface shows no frame in 5 s keeps the texture '
        'for good', (tester) async {
      final e = ExoEngine.forTest();
      e.debugEvent(<Object?, Object?>{
        'e': 'state', 'ready': true, 'buffering': false, 'ended': false
      });
      await e.useSurface(true);
      await tester.pump(const Duration(seconds: 4));
      expect(calls, ['filmSurface true']);
      await tester.pump(const Duration(seconds: 2));
      expect(calls, ['filmSurface true', 'filmSurface false']);
      expect(e.surfaceRefused, isTrue);
      await e.useSurface(true);
      expect(calls.length, 2, reason: 'never asked again');
    });

    testWidgets('paused, the wait goes on (no frame is due)', (tester) async {
      final e = ExoEngine.forTest();
      await e.useSurface(true);
      await tester.pump(const Duration(seconds: 12));
      expect(calls, ['filmSurface true']);
      e.debugEvent(<Object?, Object?>{'e': 'film', 'on': true});
      await tester.pump(const Duration(seconds: 12));
      expect(calls, ['filmSurface true']);
      expect(e.surfaceRefused, isFalse);
    });
  });

  group('PlayerGlass', () {
    tearDown(() => PlayerUi.filmBehind.value = false);

    Widget glass() => _box(const PlayerGlass(
          borderRadius: BorderRadius.all(Radius.circular(20)),
          child: SizedBox(width: 200, height: 100),
        ));

    Color? tint(WidgetTester tester) {
      final box = tester.widget<DecoratedBox>(find
          .descendant(
              of: find.byType(PlayerGlass), matching: find.byType(DecoratedBox))
          .first);
      return (box.decoration as BoxDecoration).color;
    }

    testWidgets('over the texture: the film blurred under the tint',
        (tester) async {
      await tester.pumpWidget(glass());
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(tint(tester), PlayerUi.glassTint);
    });

    testWidgets(
        'over a film on its own surface: the tint alone, no blur pass '
        '(the owner, 28 Nov: "a tint alone, as MX")', (tester) async {
      PlayerUi.filmBehind.value = true;
      await tester.pumpWidget(glass());
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tint(tester), PlayerUi.glassTintOverFilm);
      // And back when the film returns to the texture (a mirror turned on).
      PlayerUi.filmBehind.value = false;
      await tester.pump();
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    test('the tint over the film is darker than the glass', () {
      expect(PlayerUi.glassTintOverFilm.a, greaterThan(PlayerUi.glassTint.a));
      expect(PlayerUi.glassTintOverFilm.r, PlayerUi.glassTint.r);
    });
  });

  group('the player screen', () {
    setUpAll(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    testWidgets('Night mode is a black layer over the picture, not a filter',
        (tester) async {
      await pumpPlayer(tester,
          phone: const Phone('360x800', 360, 800, 2.0),
          landscape: true,
          lang: 'en');
      Finder shade() => find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == const Color(nightShadeArgb));
      expect(shade(), findsNothing);
      playerContainer!
          .read(playerControllerProvider.notifier)
          .toggleNightMode();
      await tester.pump();
      expect(shade(), findsOneWidget);
      expect(find.byType(ColorFiltered), findsNothing,
          reason: 'one layer for both surfaces, no colour matrix');
      await leavePlayer(tester);
    });
  });
}
