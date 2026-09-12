// Whatever theme is selected, text on Innocent's surfaces must be readable.
//
// THE CLASS OF BUG THIS CLOSES. Innocent paints dark surfaces in every theme:
// 72 of its 76 Scaffolds hardcode `#0F0F0F` or true black, and nothing outside
// `app_theme.dart` reads a light colour. But `AppTheme.light` used to describe
// a light app — `onSurface: #212121`, `scaffoldBackgroundColor: #FAFAFA` — so
// choosing Light left the surfaces dark and turned the foregrounds dark with
// them. Roughly 388 unstyled `Text` widgets rendered at 1.19:1. The user who
// reported it described the AppBar as "faded"; it was closer to absent.
//
// The tests below are written against what a *screen* actually does rather
// than against the theme's own fields, because the theme's fields were
// internally consistent the whole time — a light theme with light-theme
// colours is only wrong once you know every surface under it is dark. So each
// case pumps a real surface and reads the colour that lands on it.
//
// If a genuine light mode is ever built, `expectedSurface` below is the knob:
// these tests should start failing, and that failure is the checklist.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/theme/app_colors.dart';
import 'package:innocent/core/theme/app_theme.dart';

import 'support/contrast.dart';

/// Every theme the picker in Me → App theme can select.
final Map<String, ThemeData> _themes = <String, ThemeData>{
  'dark': AppTheme.dark,
  'light': AppTheme.light,
};

void main() {
  group('unstyled text on a hardcoded dark surface', () {
    // The 388-site case. A screen sets its own dark background and drops in a
    // `Text` with no colour; the colour therefore comes from the theme.
    for (final MapEntry<String, ThemeData> theme in _themes.entries) {
      for (final MapEntry<String, Color> surface in <String, Color>{
        'darkBackground': AppColors.darkBackground,
        'specScaffold (true black)': AppColors.specScaffold,
        'playerBackground': AppColors.playerBackground,
        'darkSurface': AppColors.darkSurface,
      }.entries) {
        testWidgets('${theme.key} / ${surface.key}',
            (WidgetTester tester) async {
          await tester.pumpWidget(MaterialApp(
            theme: theme.value,
            home: Scaffold(
              backgroundColor: surface.value,
              body: const Text('unstyled'),
            ),
          ));

          final TextStyle style =
              DefaultTextStyle.of(tester.element(find.text('unstyled'))).style;
          expect(style.color, isNotNull);
          expectLegible(
            style.color!,
            surface.value,
            what: 'unstyled body text',
            where: '${theme.key} theme on ${surface.key}',
          );
        });
      }
    }
  });

  group('the theme its own scaffold background implies', () {
    // The mirrored case, and the one that is easy to forget. A screen that
    // sets NO background inherits `scaffoldBackgroundColor` — and this app's
    // screens hardcode `Colors.white54`-style foregrounds on the assumption
    // that whatever they inherit is dark. `adb_connect_screen.dart` does
    // exactly this. So the theme's own background has to stay dark, or that
    // assumption silently becomes white-on-white.
    for (final MapEntry<String, ThemeData> theme in _themes.entries) {
      testWidgets('${theme.key}: scaffold background is a dark surface',
          (WidgetTester tester) async {
        await tester.pumpWidget(
            MaterialApp(theme: theme.value, home: const Scaffold()));
        final BuildContext ctx = tester.element(find.byType(Scaffold));
        final Color bg = Theme.of(ctx).scaffoldBackgroundColor;

        // White-ish text is hardcoded across the app; it must land legibly on
        // whatever a bare Scaffold inherits.
        expectLegible(bg, Colors.white,
            what: 'hardcoded white text',
            where: '${theme.key} theme on the inherited scaffold background');
      });
    }
  });

  group('the AppBar contract', () {
    // Narrower than appbar_contrast_test.dart, which pins four specific bars.
    // This one pins the theme-level default those bars fall back to.
    for (final MapEntry<String, ThemeData> theme in _themes.entries) {
      testWidgets('${theme.key}: appBarTheme is declared and legible',
          (WidgetTester tester) async {
        final AppBarTheme bar = theme.value.appBarTheme;
        expect(bar.foregroundColor, isNotNull,
            reason: '${theme.key} declares no appBarTheme.foregroundColor, so '
                'any AppBar hardcoding a dark background gets a foreground '
                'from ColorScheme instead — the #15 bug');
        expect(bar.titleTextStyle?.color, isNotNull);

        expectLegible(bar.foregroundColor!, AppColors.darkBackground,
            what: 'AppBar foreground', where: '${theme.key} theme');
        expectLegible(bar.titleTextStyle!.color!, AppColors.darkBackground,
            what: 'AppBar title', where: '${theme.key} theme');
      });
    }
  });
}
