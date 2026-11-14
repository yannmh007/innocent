// A scrub session always ends (14 Nov 2026). On the ladder a scrub holds
// ExoPlayer in scrubbing mode, where playback is suppressed: the owner, on
// Sintel, held the seek bar's thumb still on its picture past the controls'
// auto-hide (4 s); the bar left the tree mid-drag, its onChangeEnd never
// came, and the film said it played and did not move — play/pause dead —
// until another drag. Here: the real PlayerScreen on the fake engine
// (test/support/player_harness.dart), the controller's own scrub flag read.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/player_harness.dart';

const _phone = Phone('360x800', 360, 800, 2.0);

PlayerController _c() =>
    playerContainer!.read(playerControllerProvider.notifier);
PlayerState _state() => playerContainer!.read(playerControllerProvider);

/// A finger down on the seek bar, moved enough to be a drag.
Future<TestGesture> _grabBar(WidgetTester tester) async {
  final bar = find.byType(Slider);
  expect(bar, findsOneWidget);
  final g = await tester.startGesture(tester.getCenter(bar));
  await tester.pump(const Duration(milliseconds: 50));
  await g.moveBy(const Offset(30, 0));
  await tester.pump(const Duration(milliseconds: 50));
  return g;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
      'a thumb held still on the bar keeps the controls up; '
      'letting go ends the scrub', (tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    expect(_state().controlsVisible, isTrue);
    expect(_state().isPlaying, isTrue);
    final g = await _grabBar(tester);
    expect(_c().scrubbing, isTrue);
    // Held still, longer than the auto-hide (4 s by default): the bar stays.
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(_state().controlsVisible, isTrue);
    expect(find.byType(Slider), findsOneWidget);
    expect(_c().scrubbing, isTrue);
    await g.up();
    await tester.pump();
    expect(_c().scrubbing, isFalse);
    // And the auto-hide comes back once the finger is gone.
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(_state().controlsVisible, isFalse);
    await leavePlayer(tester);
  });

  testWidgets('a bar taken away mid-drag ends its scrub', (tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    final g = await _grabBar(tester);
    expect(_c().scrubbing, isTrue);
    // As a menu, a route or a forced hide would: the bar leaves the tree.
    _c().hideControls();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Slider), findsNothing);
    expect(_c().scrubbing, isFalse);
    await g.up();
    await tester.pump();
    expect(_c().scrubbing, isFalse);
    await leavePlayer(tester);
  });

  testWidgets('play / pause closes a scrub left open', (tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    _c().beginScrub();
    expect(_c().scrubbing, isTrue);
    await _c().playOrPause();
    await tester.pump();
    expect(_c().scrubbing, isFalse);
    await leavePlayer(tester);
  });

  testWidgets('a swipe-seek under the rotation lock ends its scrub',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'string_setting_lockMode': 'rotation'});
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    _c().toggleLock();
    await tester.pump();
    expect(_state().isLocked, isTrue);
    expect(_state().lockScope, 'rotation');
    // The rotation lock keeps gestures: a swipe starts a scrub…
    _c().onSeekStart();
    expect(_c().scrubbing, isTrue);
    _c().onSeekUpdate(30);
    // …and its end closes it (it used to refuse any lock, leaving it open).
    await _c().onSeekEnd();
    await tester.pump();
    expect(_c().scrubbing, isFalse);
    await leavePlayer(tester);
  });
}
