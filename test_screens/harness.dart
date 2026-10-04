// Renders app screens to PNG so they can be LOOKED AT — by a person or by
// Claude — without a phone. Not part of `flutter test` (it lives outside
// test/); run it with:
//
//   flutter test test_screens --update-goldens
//
// and the pictures land in test_screens/out/. Nothing compares them: this is
// a camera, not a regression gate. Real fonts are loaded (Roboto, Material
// Icons, and Noto Sans Myanmar as the Burmese fallback Android supplies), so
// what is drawn is what a phone draws, including Burmese line heights.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/core/theme/app_theme.dart';
import 'package:innocent/features/music/presentation/music_providers.dart';

/// A phone to draw on: logical size and pixel ratio.
class Phone {
  const Phone(this.name, this.size, {this.ratio = 1.5, this.top = 32, this.bottom = 24});
  final String name;
  final Size size;
  final double ratio;
  final double top;
  final double bottom;
}

/// Small Android (Galaxy A-series class) and a large one (S23 Ultra class).
const small = Phone('small', Size(360, 740));
const large = Phone('large', Size(412, 915));

String? _fontDir() {
  final env = Platform.environment['SCREEN_FONTS'] ?? 'build/screen_fonts';
  return Directory(env).existsSync() ? env : null;
}

Future<void> _load(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (!f.existsSync()) continue;
    final bytes = f.readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

/// Loads the fonts once. SCREEN_FONTS must point at a folder holding
/// Roboto-*.ttf, MaterialIcons-Regular.otf and NotoSansMyanmar-400/700.ttf.
///
/// On a phone, Burmese is drawn by the system's Noto Sans Myanmar as a
/// FALLBACK to Roboto, and a line holding it takes that font's (much taller)
/// height. The test engine has no system fallback, so [phoneTheme] names
/// Noto Sans Myanmar as the fallback on every style the theme hands out —
/// the same glyphs, shaping and line heights the phone uses.
Future<void> loadScreenFonts() async {
  final dir = _fontDir();
  if (dir == null) {
    throw StateError('Fonts not found: run tool/screens_fonts.sh (see test_screens/README.md).');
  }
  await _load('Roboto', [
    '$dir/Roboto-Regular.ttf',
    '$dir/Roboto-Medium.ttf',
    '$dir/Roboto-Bold.ttf',
    '$dir/Roboto-Light.ttf',
    '$dir/Roboto-Black.ttf',
  ]);
  await _load(_mm, ['$dir/NotoSansMyanmar-400.ttf', '$dir/NotoSansMyanmar-700.ttf']);
  await _load('MaterialIcons', ['$dir/MaterialIcons-Regular.otf']);
  await _load('monospace', ['$dir/Roboto-Regular.ttf']);
}

const _mm = 'NotoSansMyanmar';

/// The locale this run draws in (SCREEN_LOCALE, default my).
final Locale screenLocale = Locale(Platform.environment['SCREEN_LOCALE'] ?? 'my');

/// A theme style with no family gets the ENGINE default: Roboto on a phone,
/// the box font in a test. Naming Roboto where the theme names nothing draws
/// what the phone draws; it changes nothing on a phone.
TextStyle? _r(TextStyle? s) => s?.copyWith(
    fontFamily: s.fontFamily ?? 'Roboto', fontFamilyFallback: const [_mm]);

TextTheme _tt(TextTheme t) => t.apply(fontFamily: 'Roboto', fontFamilyFallback: const [_mm]);

ThemeData phoneTheme(ThemeData t) => t.copyWith(
      textTheme: _tt(t.textTheme),
      primaryTextTheme: _tt(t.primaryTextTheme),
      appBarTheme: t.appBarTheme.copyWith(
        titleTextStyle: _r(t.appBarTheme.titleTextStyle ?? t.textTheme.titleLarge),
        toolbarTextStyle: _r(t.appBarTheme.toolbarTextStyle ?? t.textTheme.bodyMedium),
      ),
      bottomNavigationBarTheme: t.bottomNavigationBarTheme.copyWith(
        selectedLabelStyle: _r(t.bottomNavigationBarTheme.selectedLabelStyle ?? const TextStyle()),
        unselectedLabelStyle: _r(t.bottomNavigationBarTheme.unselectedLabelStyle ?? const TextStyle()),
      ),
      snackBarTheme: t.snackBarTheme.copyWith(contentTextStyle: _r(t.snackBarTheme.contentTextStyle)),
      dialogTheme: t.dialogTheme.copyWith(
        titleTextStyle: _r(t.dialogTheme.titleTextStyle),
        contentTextStyle: _r(t.dialogTheme.contentTextStyle),
      ),
      chipTheme: t.chipTheme.copyWith(labelStyle: _r(t.chipTheme.labelStyle)),
      tabBarTheme: t.tabBarTheme.copyWith(
        labelStyle: _r(t.tabBarTheme.labelStyle),
        unselectedLabelStyle: _r(t.tabBarTheme.unselectedLabelStyle),
      ),
      listTileTheme: t.listTileTheme.copyWith(
        titleTextStyle: _r(t.listTileTheme.titleTextStyle),
        subtitleTextStyle: _r(t.listTileTheme.subtitleTextStyle),
      ),
    );

/// The music engine is libmpv, which a test cannot load. Nothing playing is
/// the state every screen starts in anyway.
class _QuietMusic extends StateNotifier<MusicPlayingState>
    implements MusicPlayingNotifier {
  _QuietMusic() : super(const MusicPlayingState());
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

List<Override> baseOverrides() => [
      musicPlayingProvider.overrideWith((ref) => _QuietMusic()),
    ];

/// Overflows and other layout errors seen while drawing, for the run log.
final List<String> problems = [];

/// Draws [child] on [phone] in [locale] and saves `out/<name>.png`.
Future<void> shoot(
  WidgetTester tester,
  String name,
  Widget child, {
  Phone phone = small,
  Locale locale = const Locale('en'),
  List<Override> overrides = const [],
  bool dark = true,
  Duration settle = const Duration(seconds: 2),
  Future<void> Function(WidgetTester)? act,
  int scrolls = 0,
  Map<String, Object> prefs = const {},
}) async {
  debugDisableShadows = false;
  _fakePlugins(prefs);
  tester.view.physicalSize = phone.size * phone.ratio;
  tester.view.devicePixelRatio = phone.ratio;
  tester.view.padding = FakeViewPadding(top: phone.top * phone.ratio, bottom: phone.bottom * phone.ratio);
  tester.view.viewPadding = FakeViewPadding(top: phone.top * phone.ratio, bottom: phone.bottom * phone.ratio);
  addTearDown(tester.view.reset);
  // SCREEN_TEXT_SCALE: draw as a phone whose font setting is not 1.0. The
  // owner's phone renders text at about 0.8 of these fonts (measured from a
  // screenshot of this app on it, 2026-10-04), which is the scale to compare
  // against screenshots taken on that phone.
  final textScale = double.tryParse(Platform.environment['SCREEN_TEXT_SCALE'] ?? '');
  if (textScale != null) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  // An overflow is a FINDING here, not a test failure: it is printed (and
  // drawn as the yellow-black stripe) and the run carries on to the picture.
  final tagFor = '${name}_${phone.name}_${locale.languageCode}';
  final binding = FlutterError.onError;
  FlutterError.onError = (details) {
    final first = details.exceptionAsString().split('\n').first;
    final where = details.context?.toDescription() ?? '';
    String? creator;
    for (final n in details.informationCollector?.call() ?? const <DiagnosticsNode>[]) {
      final t = n.toStringDeep();
      if (t.contains('lib/')) {
        creator = RegExp(r'lib/[^ :]+:\d+').firstMatch(t)?.group(0);
        if (creator != null) break;
      }
    }
    // Only LAYOUT is a finding. A plugin the test cannot answer is noise.
    final layout = first.contains('overflow') || first.contains('RenderBox was not laid out') ||
        first.contains('unbounded') || first.contains('BoxConstraints');
    final line = '${layout ? 'PROBLEM' : 'noise'} $tagFor: $first ${creator ?? where}';
    if (layout) problems.add(line);
    // ignore: avoid_print
    print(line);
  };

  final key = GlobalKey();
  await tester.pumpWidget(ProviderScope(
    overrides: [...baseOverrides(), ...overrides],
    child: RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: phoneTheme(AppTheme.light),
        darkTheme: phoneTheme(AppTheme.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        locale: locale,
        localizationsDelegates: AppStrings.localizationsDelegates,
        supportedLocales: AppStrings.supportedLocales,
        home: child,
      ),
    ),
  ));
  // Real time for the demo repository's simulated latency, then frames.
  for (var i = 0; i < 10; i++) {
    await tester.pump(settle ~/ 10);
  }
  if (act != null) {
    await act(tester);
    for (var i = 0; i < 10; i++) {
      await tester.pump(settle ~/ 10);
    }
  }
  final tag = '${name}_${phone.name}_${locale.languageCode}';
  await expectLater(find.byKey(key), matchesGoldenFile('out/$tag.png'));
  // Further down the page: one screen's height at a time, so nothing below
  // the fold goes unseen.
  for (var i = 1; i <= scrolls; i++) {
    final scrollable = find.byType(Scrollable);
    if (scrollable.evaluate().isEmpty) break;
    await tester.dragFrom(
        Offset(phone.size.width / 2, phone.size.height * 0.85),
        Offset(0, -phone.size.height * 0.7));
    for (var j = 0; j < 10; j++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await expectLater(find.byKey(key), matchesGoldenFile('out/${tag}_$i.png'));
  }
  // Take the tree down and let one-shot timers (debounces, retries) run out,
  // so the binding finds nothing pending; then hand error reporting back.
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 10));
  FlutterError.onError = binding;
  debugDisableShadows = true; // the binding checks it is back before tearDown
  // Overflow stripes are drawn into the picture, and also reported here, so
  // a run says in words which screens overflowed.
  final ex = tester.takeException();
  if (ex != null) {
    // ignore: avoid_print
    print('SCREEN $tag: $ex');
  }
}

/// Runs [body] for each phone × locale.
void screens(String name, Widget Function() build,
    {List<Override> Function()? overrides,
    List<Phone> phones = const [small, large],
    List<Locale>? locales,
    Future<void> Function(WidgetTester)? act,
    int scrolls = 0,
    Map<String, Object> prefs = const {},
    Duration settle = const Duration(seconds: 2)}) {
  for (final p in phones) {
    for (final l in locales ?? [screenLocale]) {
      testWidgets('$name ${p.name} ${l.languageCode}', timeout: const Timeout(Duration(seconds: 90)), (tester) async {
        await shoot(tester, name, build(),
            phone: p,
            locale: l,
            overrides: overrides?.call() ?? const [],
            act: act,
            scrolls: scrolls,
            prefs: prefs,
            settle: settle);
      });
    }
  }
}

final Map<String, String> _secure = {};

/// Preferences a run starts with, e.g. onboarding already done.
final Map<String, Object> _prefs = {'onboarding_completed_v1': true};
void seedPrefs(Map<String, Object> values) => _prefs.addAll(values);
Directory? _support;

/// The plugins screens touch on the way in, answered the way a fresh install
/// would: an empty support folder, an empty keystore, empty preferences.
void _fakePlugins([Map<String, Object> extra = const {}]) {
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({..._prefs, ...extra});
  _support ??= Directory.systemTemp.createTempSync('screens');
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => _support!.path);
  m.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (call) async {
    final args = (call.arguments as Map?) ?? const {};
    final k = args['key'] as String?;
    switch (call.method) {
      case 'read':
        return _secure[k];
      case 'write':
        _secure[k!] = args['value'] as String;
        return null;
      case 'readAll':
        return Map<String, String>.from(_secure);
      case 'containsKey':
        return _secure.containsKey(k);
      default:
        return null;
    }
  });
}

/// Collect FlutterError reports (overflows) instead of failing the test.
void reportOverflowsInsteadOfFailing() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final s = details.exceptionAsString();
    if (s.contains('overflowed')) {
      // ignore: avoid_print
      print('OVERFLOW: ${s.split('\n').first} — ${details.context?.toDescription() ?? ''}');
      final w = details.informationCollector?.call().map((e) => e.toString()).where((l) => l.contains('Flex') || l.contains('creator')).take(2).join(' | ');
      // ignore: avoid_print
      if (w != null && w.isNotEmpty) print('   at $w');
      return;
    }
    previous?.call(details);
  };
  debugPaintSizeEnabled = false;
}
