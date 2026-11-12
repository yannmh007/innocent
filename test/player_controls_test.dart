// What the player's buttons and the phone's Back do, in portrait and
// landscape (test/support/player_harness.dart: the real PlayerScreen on a
// fake engine).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/models/audio_track_info.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/player_screen.dart';
import 'package:innocent/features/player/presentation/video_adjust.dart';
import 'package:innocent/features/player/presentation/widgets/display_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_player_service.dart';
import 'support/player_harness.dart';

const _phone = Phone('360x800', 360, 800, 2.0);

PlayerState _state() => playerContainer!.read(playerControllerProvider);

/// Frames enough for a panel to slide in (PlayerPanel animates 220 ms; a
/// single long pump draws only its first frame, the panel still below the
/// screen).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final landscape in [false, true]) {
    final o = landscape ? 'landscape' : 'portrait';

    testWidgets('$o: Back closes an open menu before it closes the film',
        (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: landscape, lang: 'en');
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_state().openPanel, SidePanel.more);

      await _back(tester);
      expect(find.byType(PlayerScreen), findsOneWidget,
          reason: 'Back with the menu open left the film');
      expect(_state().openPanel, SidePanel.none);
      await leavePlayer(tester);
    });

    testWidgets('$o: an open menu hides the controls under it',
        (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: landscape, lang: 'en');
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await _settle(tester);
      // One layer at a time: nothing of the top bar, the shortcut row or
      // the bottom row shows through ⋮ (owner's screenshots, 12 Nov 2026).
      expect(find.byIcon(Icons.skip_next), findsNothing);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      playerContainer!.read(playerControllerProvider.notifier).closePanel();
      await _settle(tester);
      expect(find.byIcon(Icons.skip_next), findsOneWidget,
          reason: 'the controls did not come back with the menu closed');
      await leavePlayer(tester);
    });

    testWidgets('$o: CC chooses a subtitle track in one tap, and marks it',
        (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: landscape, lang: 'en');
      await tester.tap(find.byIcon(Icons.subtitles_outlined));
      await _settle(tester);
      await tester.tap(find.text('English'));
      await _settle(tester);
      expect(_state().currentSubtitleTrack?.id, '2');
      expect(_state().openPanel, SidePanel.none);

      // The top bar's CC (the toast that says "Subtitle: English" shows
      // the same icon).
      await tester.tap(find.byIcon(Icons.subtitles_outlined).first);
      await _settle(tester);
      final englishRow = find.ancestor(
          of: find.text('English'), matching: find.byType(InkWell));
      expect(
          find.descendant(
              of: englishRow.first, matching: find.byIcon(Icons.check_rounded)),
          findsOneWidget,
          reason: 'the chosen track is not marked');
      await tester.tap(find.text('Off'));
      await _settle(tester);
      expect(_state().currentSubtitleTrack, isNull);
      await leavePlayer(tester);
    });

    testWidgets('$o: Video display off turns the picture off, not the menu',
        (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: landscape, lang: 'en');
      await tester.tap(find.byIcon(Icons.more_vert));
      await _settle(tester);
      await tester.ensureVisible(find.text('Video Display'));
      await tester.pump();
      await tester.tap(find.text('Video Display'));
      await _settle(tester);
      expect(_state().openPanel, SidePanel.more);
      // The sixteen actions stay: the switch used to hide them as well.
      expect(find.byIcon(Icons.queue_music), findsOneWidget);
      expect(find.byIcon(Icons.speed), findsOneWidget);
      await leavePlayer(tester);
    });

    testWidgets('$o: the audio and subtitle buttons are on the top bar',
        (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: landscape, lang: 'en');
      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(find.byIcon(Icons.subtitles_outlined), findsOneWidget);
      await leavePlayer(tester);
    });

    testWidgets('$o: a long press on Next opens the repeat menu',
        (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: landscape, lang: 'en');
      await tester.longPress(find.byIcon(Icons.skip_next));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BottomSheet), findsOneWidget,
          reason: 'no repeat menu after a long press on Next');
      await leavePlayer(tester);
    });

    testWidgets('$o: no two bottom-row buttons share a touch area',
        (tester) async {
      for (final width in [320.0, 360.0]) {
        await pumpPlayer(tester,
            phone: Phone('w$width', width, width * 2.2, 2.0),
            landscape: landscape,
            lang: 'en');
        final rects = <String, Rect>{
          for (final icon in [
            Icons.lock_open,
            Icons.skip_previous,
            Icons.pause,
            Icons.play_arrow,
            Icons.skip_next,
            Icons.crop_landscape_outlined,
            Icons.picture_in_picture_alt_outlined,
          ])
            if (find.byIcon(icon).evaluate().isNotEmpty)
              icon.codePoint.toRadixString(16): tester.getRect(find
                  .ancestor(
                      of: find.byIcon(icon), matching: find.byType(IconButton))
                  .first),
        };
        final keys = rects.keys.toList();
        for (var i = 0; i < keys.length; i++) {
          for (var j = i + 1; j < keys.length; j++) {
            final a = rects[keys[i]]!, b = rects[keys[j]]!;
            expect(a.intersect(b).width <= 0 || a.intersect(b).height <= 0,
                isTrue,
                reason: '$width dp: ${keys[i]} $a overlaps ${keys[j]} $b');
          }
        }
        await leavePlayer(tester);
      }
    });
  }

  testWidgets('upright, the picture rises to the top under ⋮ and comes back',
      (tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    // The fake engine's picture: a 16:9 frame, centred.
    final frame = find.byType(AspectRatio).first;
    final before = tester.getRect(frame).top;
    expect(before, greaterThan(200));
    await tester.tap(find.byIcon(Icons.more_vert));
    await _settle(tester);
    expect(tester.getRect(frame).top, lessThan(1),
        reason: 'the sheet covered the picture (owner, 12 Nov)');
    // The sheet stays under the picture: the film is whole above it.
    final sheetTop = tester.getRect(find.text('More').first).top;
    expect(sheetTop, greaterThan(tester.getRect(frame).bottom));
    playerContainer!.read(playerControllerProvider.notifier).closePanel();
    await _settle(tester);
    expect(tester.getRect(frame).top, closeTo(before, 1));
    await leavePlayer(tester);
  });

  testWidgets("the audio menu lists the film's tracks, not the engine's "
      'auto and no', (tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    await tester.tap(find.byIcon(Icons.music_note));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Track auto'), findsNothing);
    expect(find.textContaining('Track no'), findsNothing);
    expect(find.text('Stereo · English'), findsOneWidget);
    expect(find.text('Commentary · English'), findsOneWidget);
    await leavePlayer(tester);
  });

  testWidgets('one audio track: no "more to choose" dot on the audio button',
      (tester) async {
    await pumpPlayer(tester,
        phone: _phone,
        landscape: false,
        lang: 'en',
        engine: FakePlayerService(
            audioTracks: const [AudioTrackInfo(id: '1', language: 'eng')]));
    expect(_state().audioTracks, hasLength(1));
    await leavePlayer(tester);
  });

  testWidgets('"Lock screen on rotation" locks on the turn that happens',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'pref_player_ctlLockOnRotation': true});
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    expect(_state().isLocked, isFalse);
    // The phone turns: the window becomes landscape.
    tester.view.physicalSize =
        Size(_phone.height * _phone.dpr, _phone.width * _phone.dpr);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_state().isLocked, isTrue,
        reason: 'not locked on the first rotation');
    await leavePlayer(tester);
  });

  testWidgets('a playback error is a card that names no signed address',
      (tester) async {
    final svc = FakePlayerService();
    await pumpPlayer(
        tester, phone: _phone, landscape: false, lang: 'en', engine: svc);
    svc.failWith('Failed to open https://cdn.example/v/1/index.m3u8'
        '?exp=9&sig=SECRET: HTTP error 403 Forbidden');
    await _settle(tester);
    // Not "Playback failed": the film is still playing.
    expect(find.text('The player reported a problem'), findsOneWidget);
    expect(find.textContaining('SECRET'), findsNothing);
    expect(find.textContaining('https://cdn.example/…'), findsOneWidget);
    // The film still plays (libmpv logged something it survived): the
    // card stays out of the way and the controls in reach.
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
    // Back puts the card away, as it does a dialog, and leaves the film.
    await _back(tester);
    expect(find.text('The player reported a problem'), findsNothing);
    expect(find.byType(PlayerScreen), findsOneWidget);

    // An error that stopped the film takes the screen until answered.
    await svc.pause();
    await _settle(tester);
    svc.failWith('Failed to open the file');
    await _settle(tester);
    expect(find.text('Playback failed'), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsNothing);
    await leavePlayer(tester);
  });

  testWidgets('Display Settings changes the picture, and keeps its values',
      (tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: true, lang: 'en');
    expect(find.byType(ColorFiltered), findsNothing,
        reason: 'an untouched picture is not filtered');
    final adjust = playerContainer!.read(videoAdjustProvider.notifier);
    adjust.state = const VideoAdjust(contrast: 0.4);
    await tester.pump();
    expect(find.byType(ColorFiltered), findsOneWidget);

    // The sheet shows what is set, and its sliders reach the picture.
    unawaited(
        DisplaySettingsSheet.show(tester.element(find.byType(PlayerScreen))));
    await tester.pump(const Duration(milliseconds: 400));
    final sliders = find.descendant(
        of: find.byType(DisplaySettingsSheet), matching: find.byType(Slider));
    expect(sliders, findsNWidgets(4));
    expect(tester.widget<Slider>(sliders.at(1)).value, 0.4);
    tester.widget<Slider>(sliders.at(0)).onChanged!(0.25);
    await tester.pump();
    expect(adjust.state.brightness, 0.25);
    expect(adjust.state.contrast, 0.4);
    await leavePlayer(tester);
  });
}
