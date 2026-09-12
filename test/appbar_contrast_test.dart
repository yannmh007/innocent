// A screen that hardcodes a dark AppBar background must hardcode its
// foreground too.
//
// THE BUG THIS EXISTS TO CATCH. `AppTheme.light` declares no `appBarTheme`,
// so an AppBar that sets `backgroundColor: AppColors.darkBackground` and
// leaves the foreground to the theme gets #212121 on #0F0F0F — a contrast
// ratio of 1.19:1. On Light or Adaptive the title and both icons are
// effectively invisible. It is silent: the analyzer cannot see it, the widget
// builds, and a developer on Dark mode never reproduces it.
//
// It reached a user on the Downloader screen. Three other screens had it too.
//
// WHY BOTH `foregroundColor` AND AN EXPLICIT TITLE COLOUR. They are not
// redundant. `AppTheme.dark.appBarTheme.titleTextStyle` carries its own
// colour (#E0E0E0), and an AppBar resolves its title style as
// `widget.titleTextStyle ?? appBarTheme.titleTextStyle ?? default(foreground)`
// — so the theme's entry outranks the widget's `foregroundColor`. Setting
// only `foregroundColor` fixes the icons and leaves a grey title above them.
//
// SO THERE ARE TWO ASSERTIONS, because one does not imply the other and each
// catches a different half of the fix. Dropping `foregroundColor` fails the
// contrast check in light mode. Dropping the title colour fails nothing on
// contrast — #E0E0E0 scores a healthy 14.5:1 — and is caught only by the
// consistency check, which is the one that notices a grey title sitting
// above white icons.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/theme/app_colors.dart';
import 'package:innocent/core/theme/app_theme.dart';

/// The AppBars, transcribed from the four screens that were repaired. Keep a
/// row in step with its screen: the point is to fail when the real one drifts.
final Map<String, AppBar Function()> _bars = <String, AppBar Function()>{
  // lib/features/downloader/presentation/downloader_home_screen.dart
  'downloader_home_screen': () => AppBar(
        backgroundColor: AppColors.darkBackground,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        title: const Text('Downloader',
            style: TextStyle(
                color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600)),
        actions: <Widget>[
          IconButton(
              icon: const Icon(Icons.tune_rounded, size: 22), onPressed: () {}),
        ],
      ),
  // lib/features/player/presentation/widgets/customise_items_screen.dart
  'customise_items_screen': () => AppBar(
        backgroundColor: AppColors.darkBackground,
        foregroundColor: Colors.white,
        title: const Text('Shortcuts', style: TextStyle(color: Colors.white)),
        actions: <Widget>[
          IconButton(icon: const Icon(Icons.tune_rounded), onPressed: () {}),
        ],
      ),
  // lib/features/transfer/presentation/folder_send_picker.dart
  'folder_send_picker': () => AppBar(
        backgroundColor: AppColors.darkBackground,
        foregroundColor: Colors.white,
        title: const Text('Send folder',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white)),
        actions: <Widget>[
          IconButton(icon: const Icon(Icons.tune_rounded), onPressed: () {}),
        ],
      ),
  // lib/features/transfer/presentation/transfer_screen.dart
  'transfer_screen': () => AppBar(
        title: const Text('File transfer',
            style: TextStyle(color: Colors.white)),
        backgroundColor: AppColors.darkBackground,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: <Widget>[
          IconButton(
              icon: const Icon(Icons.tune_rounded, size: 22), onPressed: () {}),
        ],
      ),
};

/// WCAG relative luminance, so the assertion is about legibility rather than
/// about one particular shade of white.
double _luminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _contrast(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  /// Pushes a second route so the automatic back button exists — it is one of
  /// the three things that went invisible, and it only appears when
  /// `Navigator.canPop()` is true.
  Future<void> pumpBar(WidgetTester tester, ThemeData theme, AppBar bar) async {
    await tester.pumpWidget(MaterialApp(theme: theme, home: const Scaffold()));
    final NavigatorState nav = tester.state(find.byType(Navigator).last);
    // Deliberately not awaited: `push` completes only when the route is
    // popped, and this one never is. `pumpAndSettle` below is what waits for
    // the transition to finish.
    unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) =>
            Scaffold(backgroundColor: AppColors.darkBackground, appBar: bar))));
    await tester.pumpAndSettle();
  }

  Color? colourOf(WidgetTester tester, Finder f) {
    final Icon icon = tester.widget(f);
    return icon.color ?? IconTheme.of(tester.element(f)).color;
  }

  for (final MapEntry<String, ThemeData> theme in <String, ThemeData>{
    'dark': AppTheme.dark,
    'light': AppTheme.light,
  }.entries) {
    group('${theme.key} theme', () {
      for (final MapEntry<String, AppBar Function()> bar in _bars.entries) {
        testWidgets('${bar.key} stays legible', (WidgetTester tester) async {
          await pumpBar(tester, theme.value, bar.value());

          final Text title = tester.widget(find.textContaining(RegExp('.')));
          final TextStyle style =
              DefaultTextStyle.of(tester.element(find.byWidget(title)))
                  .style
                  .merge(title.style);

          final Color? titleColour = style.color;
          final Color? actionColour =
              colourOf(tester, find.byIcon(Icons.tune_rounded));
          final Color? backColour =
              colourOf(tester, find.byIcon(Icons.arrow_back));

          expect(titleColour, isNotNull);
          expect(actionColour, isNotNull);
          expect(backColour, isNotNull);

          final Map<String, Color?> parts = <String, Color?>{
            'title': titleColour,
            'action icon': actionColour,
            'back arrow': backColour,
          };

          // 1. LEGIBILITY. Each of the three must clear WCAG AA for large
          //    text against the bar's own hardcoded background. The shipped
          //    regression scored 1.19:1.
          for (final MapEntry<String, Color?> part in parts.entries) {
            expect(
              _contrast(part.value!, AppColors.darkBackground),
              greaterThan(4.5),
              reason: '${bar.key}: ${part.key} is illegible in '
                  '${theme.key} mode',
            );
          }

          // 2. CONSISTENCY. Legible is not enough — a #E0E0E0 title scores
          //    14.5:1 and still reads as washed out next to white icons and
          //    the pure-white body beneath it. This is the assertion that
          //    fails if the explicit title colour is ever removed, and the
          //    reason it is not redundant with the contrast check above.
          expect(
            parts.values.toSet(),
            hasLength(1),
            reason: '${bar.key}: title, action icon and back arrow do not '
                'match in ${theme.key} mode — $parts',
          );
        });
      }
    });
  }
}
