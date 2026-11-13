// What the player's buttons and the phone's Back do, in portrait and
// landscape (test/support/player_harness.dart: the real PlayerScreen on a
// fake engine).
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/models/audio_track_info.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/player_screen.dart';
import 'package:innocent/features/player/presentation/video_adjust.dart';
import 'package:innocent/features/player/presentation/widgets/display_settings_sheet.dart';
import 'package:innocent/features/player/presentation/widgets/more_menu_panel.dart';
import 'package:innocent/features/player/presentation/widgets/player_ui.dart';
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
      // A bottom sheet upright, a side panel sideways: its rows either way.
      expect(find.text('Loop one'), findsOneWidget,
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

  testWidgets('menus are frosted glass, and the picture stays where it is',
      (tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    final frame = find.byType(AspectRatio).first;
    final before = tester.getRect(frame);
    await tester.tap(find.byIcon(Icons.more_vert));
    await _settle(tester);
    expect(
        find.descendant(
            of: find.byType(MoreMenuPanel), matching: find.byType(BackdropFilter)),
        findsOneWidget,
        reason: 'the menu is not glass (owner, 12 Nov)');
    // The owner chose glass over moving the film (12 Nov).
    expect(tester.getRect(frame), before);
    // Upright, the sheet stops at 55 % of the screen.
    final sheet = tester.getRect(find.byType(PlayerGlass).first);
    expect(sheet.height, lessThanOrEqualTo(_phone.height * 0.55 + 0.5));
    await leavePlayer(tester);
  });

  testWidgets('sideways, a player sheet is a glass panel from the right',
      (tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: true, lang: 'en');
    await tester.longPress(find.byIcon(Icons.skip_next));
    await _settle(tester);
    expect(find.text('Loop one'), findsOneWidget);
    final glass = tester.getRect(find.byType(PlayerGlass).last);
    // The whole height, at the right edge: not a bottom sheet that held two
    // rows (12 Nov).
    expect(glass.height, closeTo(_phone.width, 0.5));
    expect(glass.right, closeTo(_phone.height, 0.5));
    expect(glass.width, lessThan(_phone.height * 0.6));
    await leavePlayer(tester);
  });

  testWidgets(
      'a sheet open while the phone turns follows the turn, its content kept',
      (tester) async {
    // A phone with auto-rotate, or a tablet's window that Android 16 lets
    // turn whatever the player asks (docs/devices_2026_11.md): the sheet
    // chose its form once, on opening, and a bottom sheet turned sideways
    // was some 300 dp tall.
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    await tester.longPress(find.byIcon(Icons.skip_next));
    await _settle(tester);
    final content = tester.element(find.text('Loop one'));
    var glass = tester.getRect(find.byType(PlayerGlass).last);
    expect(glass.bottom, closeTo(_phone.height, 0.5), reason: 'not at the foot');
    expect(glass.width, closeTo(_phone.width, 0.5));

    Future<void> turn(bool sideways) async {
      tester.view.physicalSize = sideways
          ? Size(_phone.height * _phone.dpr, _phone.width * _phone.dpr)
          : Size(_phone.width * _phone.dpr, _phone.height * _phone.dpr);
      await _settle(tester);
    }

    await turn(true);
    glass = tester.getRect(find.byType(PlayerGlass).last);
    expect(glass.height, closeTo(_phone.width, 0.5),
        reason: 'sideways, not the whole height');
    expect(glass.right, closeTo(_phone.height, 0.5));
    expect(glass.width, lessThan(_phone.height * 0.6));
    expect(identical(tester.element(find.text('Loop one')), content), isTrue,
        reason: 'the turn rebuilt the sheet\'s content from scratch');

    await turn(false);
    glass = tester.getRect(find.byType(PlayerGlass).last);
    expect(glass.bottom, closeTo(_phone.height, 0.5));
    expect(glass.width, closeTo(_phone.width, 0.5));
    expect(identical(tester.element(find.text('Loop one')), content), isTrue);
    expect(find.byType(PlayerScreen), findsOneWidget);
    await leavePlayer(tester);
  });

  testWidgets(
      'the window turns and resizes mid-film: not reopened, its place and an '
      'open menu kept', (tester) async {
    // What Android 16 does to a tablet whatever the player asks (orientation
    // requests ignored from 600 dp for an app that targets 36), and what a
    // phone with auto-rotate and a resized desktop window do already.
    final engine = FakePlayerService();
    await pumpPlayer(tester,
        phone: _phone, landscape: false, lang: 'en', engine: engine);
    await tester.tap(find.byIcon(Icons.more_vert));
    await _settle(tester);
    expect(_state().openPanel, SidePanel.more);
    int opens() => engine.calls.where((c) => c == 'open').length;
    final opened = opens();
    final place = engine.position;
    for (final size in <Size>[
      Size(_phone.height, _phone.width), // turned
      const Size(1280, 800), // a tablet's window, sideways
      const Size(800, 1280), // and upright, the lock ignored
      Size(_phone.width, _phone.height),
    ]) {
      tester.view.physicalSize = size * _phone.dpr;
      await _settle(tester);
      expect(_state().openPanel, SidePanel.more, reason: '$size closed ⋮');
      expect(find.byType(MoreMenuPanel), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$size');
    }
    expect(opens(), opened, reason: 'a turn reopened the film');
    expect(engine.position, place, reason: 'a turn moved the film');
    expect(find.byType(PlayerScreen), findsOneWidget);
    await leavePlayer(tester);
  });

  testWidgets('upright, a sheet dragged down closes; a short drag does not',
      (tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    await tester.longPress(find.byIcon(Icons.skip_next));
    await _settle(tester);
    final handle = find.byType(PlayerDragHandle);
    expect(handle, findsOneWidget);
    final top = tester.getRect(find.byType(PlayerGlass).last).top;
    await tester.drag(handle, const Offset(0, 30));
    await _settle(tester);
    expect(find.text('Loop one'), findsOneWidget);
    expect(tester.getRect(find.byType(PlayerGlass).last).top,
        closeTo(top, 0.5), reason: 'a short drag did not settle back');
    await tester.drag(handle, const Offset(0, 400));
    await _settle(tester);
    expect(find.text('Loop one'), findsNothing);
    expect(find.byType(PlayerScreen), findsOneWidget);
    await leavePlayer(tester);
  });

  testWidgets(
      'a film has a media session while the player is open, and a voice '
      'command on it reaches the player', (tester) async {
    // The TV's "pause" and "skip 30 seconds" go to the playing app's media
    // session; the only one was background play's, so a film had none
    // (PlayerMediaSession, 13 Nov).
    final calls = <MethodCall>[];
    const channel = MethodChannel('mx_clone/playback');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      return true;
    });
    await pumpPlayer(tester, phone: _phone, landscape: true, lang: 'en');
    List<MethodCall> updates() =>
        calls.where((c) => c.method == 'sessionUpdate').toList();
    expect(updates(), isNotEmpty, reason: 'no session for the film');
    final first = updates().last.arguments as Map;
    expect(first['title'], contains('The Long Road Home'));
    expect(first['isPlaying'], isTrue);
    expect(first['durationMs'], greaterThan(0));

    // "Pause", from the TV: the session's command, as the notification's.
    Future<void> command(String action, [int positionMs = -1]) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall('onPlaybackAction',
              {'action': action, 'positionMs': positionMs})),
          (_) {});
      await _settle(tester);
    }

    await command('pause');
    expect(_state().isPlaying, isFalse);
    expect((updates().last.arguments as Map)['isPlaying'], isFalse,
        reason: 'the session was not told the film paused');

    // "Skip 30 seconds" arrives as a seek to a place; the session hears the
    // jump at once rather than at its next tick.
    final before = updates().length;
    await command('seek', 30 * 60 * 1000);
    expect(_state().position.inMinutes, 30);
    expect(updates().length, greaterThan(before));

    await leavePlayer(tester);
    expect(calls.any((c) => c.method == 'sessionStop'), isTrue,
        reason: 'the session outlived the player');
  });

  testWidgets('a remote\'s and a keyboard\'s keys reach the player',
      (tester) async {
    final svc = FakePlayerService();
    await pumpPlayer(
        tester, phone: _phone, landscape: true, lang: 'en', engine: svc);
    // The TV quality guideline's media keys, wherever focus is.
    final playing = _state().isPlaying;
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await _settle(tester);
    expect(_state().isPlaying, !playing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await _settle(tester);
    expect(_state().isPlaying, playing);
    final seeks = svc.calls.where((c) => c == 'seek').length;
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await _settle(tester);
    expect(svc.calls.where((c) => c == 'seek').length, seeks + 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await _settle(tester);
    expect(_state().isMuted, isTrue);
    // ☰ opens ⋮, Esc puts it away and leaves the film playing.
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await _settle(tester);
    expect(_state().openPanel, SidePanel.more);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(_state().openPanel, SidePanel.none);
    expect(find.byType(PlayerScreen), findsOneWidget);
    // ? lists the keys.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await _settle(tester);
    expect(find.text('Keyboard and remote'), findsOneWidget);
    await leavePlayer(tester);
  });

  testWidgets('a mouse: moving shows the controls, a right-click opens ⋮',
      (tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: true, lang: 'en');
    playerContainer!.read(playerControllerProvider.notifier).hideControls();
    await _settle(tester);
    expect(_state().controlsVisible, isFalse);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 180));
    await mouse.moveTo(const Offset(420, 190));
    await _settle(tester);
    expect(_state().controlsVisible, isTrue);
    await mouse.removePointer();
    await tester.tapAt(const Offset(420, 200),
        buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await _settle(tester);
    expect(_state().openPanel, SidePanel.more);
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
