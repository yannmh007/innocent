// The player screen in a widget test: a phone of a given size and
// orientation, the app's theme and languages, a fake engine
// (fake_player_service.dart), and the phone's own services answering
// nothing. Used by test/player_layout_test.dart (photographs and geometry)
// and test/player_controls_test.dart (what the buttons do).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:innocent/core/di/core_providers.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/core/services/video_player/models/audio_track_info.dart';
import 'package:innocent/core/services/video_player/models/subtitle_track_info.dart';
import 'package:innocent/core/theme/app_theme.dart';
import 'package:innocent/features/player/presentation/player_screen.dart';

import 'fake_player_service.dart';

/// A phone: its size in dp, its pixel ratio, and its system bars in dp.
class Phone {
  const Phone(this.name, this.width, this.height, this.dpr,
      {this.statusBar = 24, this.navBar = 48, this.cutout = 0});
  final String name;
  final double width;
  final double height;
  final double dpr;
  final double statusBar;
  final double navBar;

  /// A camera cutout on the short edge: at the top in portrait, at the
  /// left in landscape.
  final double cutout;
}

const phones = <Phone>[
  // A 720p budget phone: the most common screen among this app's viewers.
  Phone('360x800', 360, 800, 2.0, statusBar: 28, navBar: 48),
  // The owner's phone (1080x2316 at 2.625), three-button navigation.
  Phone('411x882', 411.4, 882.3, 2.625, statusBar: 30, navBar: 51.4, cutout: 30),
  // A small screen, or a large "display size" setting on a 360 dp phone.
  Phone('320x640', 320, 640, 2.0, statusBar: 24, navBar: 48),
];

final shotsDir = Platform.environment['PLAYER_SHOTS'];
/// Real fonts, so text has its real width and height: the layout test's
/// whole point (Burmese lines are nearly twice as tall as Latin ones).
/// From FONT_DIR when set; otherwise Roboto and the Material icons from the
/// Flutter SDK running the test, and Noto Sans Myanmar and Thai from
/// test/fonts (SIL OFL 1.1, test/fonts/README.md).
final fontDir = Platform.environment['FONT_DIR'];

String? _sdkFonts() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final candidates = <String>[
    if (root != null) '$root/bin/cache/artifacts/material_fonts',
    // flutter_tester lives in bin/cache/artifacts/engine/<platform>/.
    '${File(Platform.resolvedExecutable).parent.parent.parent.path}/material_fonts',
  ];
  for (final c in candidates) {
    if (File('$c/Roboto-Regular.ttf').existsSync()) return c;
  }
  return null;
}

/// Loads the fonts; true when every one was found.
Future<bool> loadPlayerFonts() async {
  final dir = fontDir;
  final sdk = dir ?? _sdkFonts();
  final own = dir ?? 'test/fonts';
  var all = true;
  Future<void> family(String name, String? from, List<String> files) async {
    final loader = FontLoader(name);
    var any = false;
    for (final f in files) {
      final file = File('$from/$f');
      if (from == null || !file.existsSync()) {
        all = false;
        continue;
      }
      final bytes = file.readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      any = true;
    }
    if (any) await loader.load();
  }

  await family('Roboto', sdk, [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]);
  await family('MaterialIcons', sdk, ['MaterialIcons-Regular.otf']);
  await family('NotoSansMyanmar', own, ['NotoSansMyanmar.ttf']);
  await family('NotoSansThai', own, ['NotoSansThai.ttf']);
  return all;
}

ThemeData playerTestTheme() {
  final t = AppTheme.dark;
  // On a phone the system supplies Myanmar and Thai glyphs behind Roboto;
  // the test engine needs to be told where they are.
  const fallback = <String>['NotoSansMyanmar', 'NotoSansThai'];
  return t.copyWith(
    textTheme: t.textTheme.apply(fontFamilyFallback: fallback),
    primaryTextTheme: t.primaryTextTheme.apply(fontFamilyFallback: fallback),
  );
}

final playerBoundary = GlobalKey();
ProviderContainer? playerContainer;

/// The phone's own services (wake lock, keys, PiP, brightness …) answer
/// nothing, as an engine with no implementation; a Pigeon channel gets the
/// empty reply it expects.
void quietPlatform(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.allMessagesHandler =
      (String channel, MessageHandler? handler, ByteData? message) async {
    if (channel.startsWith('dev.flutter.pigeon.')) {
      return const StandardMessageCodec().encodeMessage(<Object?>[null]);
    }
    if (handler != null) return handler(message);
    return null;
  };
  addTearDown(
      () => tester.binding.defaultBinaryMessenger.allMessagesHandler = null);
}

/// Leaves the player as a viewer does (the screen goes, the app stays) and
/// lets every timer it left run out.
Future<void> leavePlayer(WidgetTester tester) async {
  final c = playerContainer;
  if (c == null) return;
  await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const SizedBox()));
  await tester.pump(const Duration(minutes: 5));
  c.dispose();
  playerContainer = null;
}

Future<void> pumpPlayer(
  WidgetTester tester, {
  required Phone phone,
  required bool landscape,
  required String lang,
  double textScale = 1.0,
  FakePlayerService? engine,
}) async {
  final w = landscape ? phone.height : phone.width;
  final h = landscape ? phone.width : phone.height;
  tester.view.devicePixelRatio = phone.dpr;
  tester.view.physicalSize = Size(w * phone.dpr, h * phone.dpr);
  // Immersive: the bars are hidden while a film plays, so the window
  // reports no padding; the cutout stays.
  tester.view.padding = landscape
      ? FakeViewPadding(left: phone.cutout * phone.dpr)
      : FakeViewPadding(top: phone.cutout * phone.dpr);
  tester.view.viewPadding = tester.view.padding;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  quietPlatform(tester);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final svc = engine ??
      FakePlayerService(
        audioTracks: const [
          AudioTrackInfo(id: '1', title: 'Stereo', language: 'eng'),
          AudioTrackInfo(id: '2', title: 'Commentary', language: 'eng'),
        ],
        subtitleTracks: const [
          SubtitleTrackInfo(id: '1', language: 'mya', title: 'မြန်မာ'),
          SubtitleTrackInfo(id: '2', language: 'eng', title: 'English'),
        ],
      );
  final container = ProviderContainer(
      overrides: [videoPlayerServiceProvider.overrideWithValue(svc)]);
  playerContainer = container;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: playerBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: playerTestTheme(),
          darkTheme: playerTestTheme(),
          themeMode: ThemeMode.dark,
          locale: Locale(lang),
          localizationsDelegates: AppStrings.localizationsDelegates,
          supportedLocales: AppStrings.supportedLocales,
          // As in the app: the player is pushed over another screen, so
          // Back has somewhere to go.
          routerConfig: GoRouter(
            initialLocation: '/player',
            routes: [
              GoRoute(
                path: '/',
                builder: (_, __) => const Scaffold(
                    body: Center(child: Text('home', key: ValueKey('home')))),
                routes: [
                  GoRoute(
                    path: 'player',
                    builder: (_, __) => const PlayerScreen(
                      videoUri:
                          'file:///storage/emulated/0/Movies/The Long Road Home (2024) 1080p WEB-DL.mkv',
                      title: 'The Long Road Home (2024) 1080p WEB-DL.mkv',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  // Open, first frame, controls up.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> shootPlayer(WidgetTester tester, String name) async {
  final dir = shotsDir;
  if (dir == null) return;
  await tester.pump();
  final boundary =
      playerBoundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = File('$dir/$name.png');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(png!.buffer.asUint8List());
  });
}

