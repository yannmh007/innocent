// The player's menus stay smooth (27 Nov 2026, the owner on 1.64.89:
// "⋮'s menu stutters and lags when scrolled"). What was found, and what
// these hold:
//  * each second of the film rebuilt the whole screen, ⋮ open over it —
//    707 elements a tick (PlayerState.look now: the seek bar and its
//    times alone follow the position);
//  * each frame of a scroll painted the whole list again, and Impeller
//    keeps a word's blurred halo only while the same recorded word is drawn
//    again — so every frame blurred every word's three shadows from nothing
//    (132 blurs a frame under ⋮). A list now sits in a layer of its own
//    (RepaintBoundary): recorded once, moved by the scroll;
//  * with the controls up, a tick repainted the top bar's words with the
//    bottom row's: each bar is its own layer now.
// A widget test cannot time a GPU; it counts what is rebuilt and which
// layers are recorded again (the phones' numbers: the smoothness lab,
// lib/features/player/presentation/lab/smooth_lab.dart).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/player_screen.dart';
import 'package:innocent/features/player/presentation/widgets/display_settings_sheet.dart';
import 'package:innocent/features/player/presentation/widgets/player_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_player_service.dart';
import 'support/player_harness.dart';

/// The owner's phone.
const _phone =
    Phone('384x823', 384, 823.5, 2.8125, statusBar: 30, navBar: 48, cutout: 30);

PlayerState _state() => playerContainer!.read(playerControllerProvider);
PlayerController _controller() =>
    playerContainer!.read(playerControllerProvider.notifier);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Elements of the player screen rebuilt while [body] runs, by type.
Future<Map<String, int>> _rebuilt(Future<void> Function() body) async {
  final by = <String, int>{};
  debugOnRebuildDirtyWidget = (e, _) {
    var inPlayer = false;
    e.visitAncestorElements((a) {
      if (a.widget is PlayerScreen) inPlayer = true;
      return !inPlayer;
    });
    if (!inPlayer && e.widget is! PlayerScreen) return;
    final n = e.widget.runtimeType.toString();
    by[n] = (by[n] ?? 0) + 1;
  };
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  return by;
}

/// What a layer of its own holds now: its children's identities. A layer
/// painted again gets new picture layers; one only moved keeps them.
int _recorded(RenderObject boundary) {
  var h = 0;
  Layer? c = (boundary.debugLayer! as ContainerLayer).firstChild;
  while (c != null) {
    h = h * 31 + identityHashCode(c);
    c = c.nextSibling;
  }
  return h;
}

/// The nearest layer of its own above [finder]'s first match.
RenderObject _boundaryAbove(WidgetTester tester, Finder finder) {
  RenderObject? r = tester.renderObject(finder.first).parent;
  while (r != null && !r.isRepaintBoundary) {
    r = r.parent;
  }
  return r!;
}

/// Flings the list under [at] up by [dy] in 16 ms frames, then lets it
/// settle; returns the scroll offsets it went through.
Future<void> _scroll(WidgetTester tester, Offset at, double dy,
    {required void Function() eachFrame}) async {
  final g = await tester.startGesture(at);
  for (var i = 0; i < 20; i++) {
    await g.moveBy(Offset(0, -dy / 20));
    await tester.pump(const Duration(milliseconds: 16));
    eachFrame();
  }
  await g.up();
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    eachFrame();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final landscape in [false, true]) {
    final o = landscape ? 'landscape' : 'portrait';

    testWidgets('$o: with ⋮ open, a second of the film rebuilds nothing',
        (tester) async {
      final svc = FakePlayerService();
      await pumpPlayer(tester,
          phone: _phone, landscape: landscape, lang: 'my', engine: svc);
      _controller().openMoreMenu();
      await _settle(tester);
      expect(find.byType(PanelTile), findsWidgets);
      var p = svc.position;
      final by = await _rebuilt(() async {
        for (var i = 0; i < 5; i++) {
          p += const Duration(seconds: 1);
          svc.playTo(p);
          await tester.pump(const Duration(seconds: 1));
        }
      });
      // The position still reached the state (closing ⋮ shows it at once).
      expect(_state().position.inSeconds, p.inSeconds);
      expect(by, isEmpty, reason: 'rebuilt under ⋮ by the ticks: $by');
      await leavePlayer(tester);
    });

    testWidgets('$o: ⋮ scrolled is moved, not painted again', (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: landscape, lang: 'my');
      _controller().openMoreMenu();
      await _settle(tester);
      final tile = find.byType(PanelTile);
      final list = _boundaryAbove(tester, tile);
      // The list's own layer, inside the scroll — not the viewport, which
      // moves it.
      expect(list, isA<RenderRepaintBoundary>());
      final scroll = tester
          .state<ScrollableState>(find.ancestor(
              of: tile.first, matching: find.byType(Scrollable)))
          .position;
      final before = _recorded(list);
      var moved = false;
      await _scroll(tester, tester.getCenter(tile.at(4)), 240,
          eachFrame: () => moved |= scroll.pixels > 1);
      expect(moved, isTrue, reason: '⋮ did not scroll');
      expect(_recorded(list), before,
          reason: 'the scroll painted ⋮\'s words again');
      await leavePlayer(tester);
    });

    testWidgets('$o: CC and Display scroll the same way', (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: landscape, lang: 'my');
      _controller().openSubtitleMenu();
      await _settle(tester);
      final ccList = _boundaryAbove(
          tester,
          find.descendant(
              of: find.descendant(
                  of: find.byType(PlayerPanel),
                  matching: find.byType(SingleChildScrollView)),
              matching: find.byType(Text)));
      expect(ccList, isA<RenderRepaintBoundary>(),
          reason: 'CC\'s list has no layer of its own');
      _controller().closePanel();
      await _settle(tester);

      final ctx = tester.element(find.byType(PlayerScreen));
      // ignore: discarded_futures
      DisplaySettingsSheet.show(ctx);
      await _settle(tester);
      final sheetText = find.descendant(
          of: find.byType(DisplaySettingsSheet),
          matching: find.byType(Text));
      expect(sheetText, findsWidgets);
      final sheetList = _boundaryAbove(tester, sheetText.at(2));
      expect(sheetList, isA<RenderRepaintBoundary>(),
          reason: 'Display\'s list has no layer of its own');
      final before = _recorded(sheetList);
      await _scroll(tester, tester.getCenter(sheetText.at(2)), 200,
          eachFrame: () {});
      expect(_recorded(sheetList), before);
      Navigator.of(ctx).pop();
      await _settle(tester);
      await leavePlayer(tester);
    });

    testWidgets('$o: controls up, a tick repaints the times, not the top bar',
        (tester) async {
      final svc = FakePlayerService();
      await pumpPlayer(tester,
          phone: _phone, landscape: landscape, lang: 'en', engine: svc);
      _controller().showControls();
      await _settle(tester);
      final title = find.textContaining('The Long Road Home');
      expect(title, findsOneWidget);
      final topBar = _boundaryAbove(tester, title);
      final before = _recorded(topBar);
      final at = svc.position + const Duration(seconds: 3);
      final by = await _rebuilt(() async {
        svc.playTo(at);
        await tester.pump(const Duration(milliseconds: 300));
      });
      // The elapsed time moved with the film…
      final m = at.inMinutes.remainder(60).toString().padLeft(2, '0');
      final sec = at.inSeconds.remainder(60).toString().padLeft(2, '0');
      expect(find.text('$m:$sec'), findsOneWidget);
      // …and the rest stood still.
      expect(_recorded(topBar), before,
          reason: 'the tick painted the top bar\'s words again');
      expect(by['PlayerScreen'], isNull, reason: 'the whole screen rebuilt');
      await leavePlayer(tester);
    });

    testWidgets('$o: an open menu at rest draws through no translucent layer',
        (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: landscape, lang: 'en');
      _controller().openMoreMenu();
      await _settle(tester);
      final alphas = <int>[];
      void walk(Layer l) {
        if (l is OpacityLayer) alphas.add(l.alpha ?? 255);
        if (l is ContainerLayer) {
          var c = l.firstChild;
          while (c != null) {
            walk(c);
            c = c.nextSibling;
          }
        }
      }

      walk(tester.binding.renderViews.first.debugLayer!);
      // The slide-in's fade ended at 1: the engine skips an opaque
      // layer's saveLayer (LayerStateStack.applyOpacity).
      expect(alphas.where((a) => a < 255), isEmpty);
      await leavePlayer(tester);
    });
  }
}
