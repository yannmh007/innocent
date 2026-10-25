import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/theme/app_theme.dart';
import 'package:innocent/features/player/presentation/widgets/player_toast.dart';

/// The player's passing messages (player_toast.dart): dark, near the top,
/// one at a time, gone when read — and the app's SnackBars dark too.
void main() {
  Widget host(PlayerToastController c) => MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [PlayerToastView(controller: c, top: 100)]),
        ),
      );

  testWidgets('shown near the top, then gone once read', (tester) async {
    final c = PlayerToastController();
    await tester.pumpWidget(host(c));
    c.show('Loaded: film.srt');
    await tester.pumpAndSettle();
    expect(find.text('Loaded: film.srt'), findsOneWidget);
    // Never over the bottom controls: it starts where it was put.
    expect(tester.getTopLeft(find.byType(PlayerToastPill)).dy, greaterThanOrEqualTo(100));
    await tester.pump(PlayerToastController.readingTime('Loaded: film.srt', PlayerToastKind.info));
    await tester.pumpAndSettle();
    expect(find.text('Loaded: film.srt'), findsNothing);
    c.dispose();
  });

  testWidgets('a busy message stays until the next replaces it', (tester) async {
    final c = PlayerToastController();
    await tester.pumpWidget(host(c));
    c.show('Switching to 480p…', kind: PlayerToastKind.busy);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Switching to 480p…'), findsOneWidget);
    c.show('Now playing 480p', kind: PlayerToastKind.success);
    await tester.pumpAndSettle();
    expect(find.text('Switching to 480p…'), findsNothing);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    c.hide();
    await tester.pumpAndSettle();
    c.dispose();
  });

  testWidgets('a tap puts it away', (tester) async {
    final c = PlayerToastController();
    await tester.pumpWidget(host(c));
    c.show('Bookmark added at 03:30', kind: PlayerToastKind.success);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PlayerToastPill));
    await tester.pumpAndSettle();
    expect(c.value, isNull);
    c.dispose();
  });

  testWidgets('a screen reader hears it once, as a live region', (tester) async {
    final handle = tester.ensureSemantics();
    final c = PlayerToastController();
    await tester.pumpWidget(host(c));
    c.show('Could not switch', kind: PlayerToastKind.warning);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byType(PlayerToastPill)),
      matchesSemantics(label: 'Could not switch', isLiveRegion: true),
    );
    c.hide();
    await tester.pumpAndSettle();
    c.dispose();
    handle.dispose();
  });

  test('reading time: two seconds at least, seven at most, longer for a warning', () {
    expect(PlayerToastController.readingTime('Hi', PlayerToastKind.info), const Duration(milliseconds: 2090));
    expect(PlayerToastController.readingTime('x' * 400, PlayerToastKind.info), const Duration(seconds: 7));
    expect(
      PlayerToastController.readingTime('Could not switch', PlayerToastKind.warning) >
          PlayerToastController.readingTime('Could not switch', PlayerToastKind.info),
      isTrue,
    );
  });

  test('the app\'s SnackBars are dark and floating', () {
    final t = AppTheme.dark.snackBarTheme;
    expect(t.behavior, SnackBarBehavior.floating);
    expect(t.backgroundColor!.computeLuminance(), lessThan(0.05));
    expect(t.contentTextStyle!.color, Colors.white);
  });
}
