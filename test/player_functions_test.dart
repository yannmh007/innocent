// Every button of ⋮, its More page and the shortcut row does something
// (27 Nov 2026, the smoothness session: "check that every function really
// works: ⋮'s ten tiles and every More row, the fourteen shortcuts").
//
// Each is tapped on a fresh player (the owner's phone; ⋮ and More upright,
// the shortcuts both ways round) and what it did is read back: a panel or
// a sheet, a dialog, a page, a message, the player's state, or a call to
// the phone. A button that does none of these is dead; each also has the
// effect it is meant to have (`expect…`). `FUNCTIONS_OUT=<file>` writes
// what every button did, one line each.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/player_screen.dart';
import 'package:innocent/features/player/presentation/shortcut_item.dart';
import 'package:innocent/features/player/presentation/widgets/player_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_player_service.dart';
import 'support/player_harness.dart';

const _phone =
    Phone('384x823', 384, 823.5, 2.8125, statusBar: 30, navBar: 48, cutout: 30);

PlayerState _state() => playerContainer!.read(playerControllerProvider);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

final _log = <String>[];

/// What the screen holds: the kinds of widget on it, its words.
({Set<String> types, Set<String> words}) _look(WidgetTester tester) {
  final types = <String>{};
  final words = <String>{};
  for (final e in find.byWidgetPredicate((_) => true).evaluate()) {
    types.add(e.widget.runtimeType.toString());
    final w = e.widget;
    if (w is Text && w.data != null) words.add(w.data!);
  }
  return (types: types, words: words);
}

/// The player's state as a few words that can be compared.
String _stateWords(PlayerState s) => [
      'panel=${s.openPanel.name}',
      'night=${s.isNightMode}',
      'shuffle=${s.isShuffleEnabled}',
      'loop=${s.loopMode}',
      'mute=${s.isMuted}',
      'sleep=${s.sleepTimerDialogOpen}',
      'bg=${s.isBackgroundPlay}',
      'mirror=${s.isMirrorMode}',
      'flip=${s.isVerticalFlip}',
      'kids=${s.isKidsLocked}',
      'decoder=${s.decoderDialogOpen}',
      'speed=${s.playbackSpeed}',
      'ab=${s.abPointA}',
    ].join(' ');

/// Taps [target] and returns what changed.
Future<String> _effect(WidgetTester tester, Finder target,
    List<String> channels) async {
  final before = _look(tester);
  final stateBefore = _stateWords(_state());
  channels.clear();
  await tester.ensureVisible(target.first);
  await tester.pump();
  await tester.tap(target.first, warnIfMissed: false);
  await _settle(tester);
  // What came, at each look: a message passes in 2 s, and what waits on the
  // phone's storage or a picture (favourites, playlists, a screenshot)
  // finishes in real time.
  final seenTypes = <String>{}..addAll(_look(tester).types);
  final seenWords = <String>{}..addAll(_look(tester).words);
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await _settle(tester);
    final l = _look(tester);
    seenTypes.addAll(l.types);
    seenWords.addAll(l.words);
  }
  final after = (types: seenTypes, words: seenWords);
  final stateAfter = _stateWords(_state());
  final newTypes = after.types.difference(before.types)
    ..removeWhere((t) => t.startsWith('_') && !t.contains('Sheet'));
  final newWords = after.words.difference(before.words);
  // What a person sees first: a sheet, a dialog, a page, a panel.
  const kinds = ['Sheet', 'Dialog', 'Screen', 'Panel', 'Card', 'Bar', 'Overlay'];
  final shown = (newTypes.toList()..sort())
      .where((t) => kinds.any(t.contains))
      .toList();
  final parts = <String>[
    if (stateAfter != stateBefore)
      'state: ${_diff(stateBefore, stateAfter)}',
    if (shown.isNotEmpty) 'shows: ${shown.join(', ')}',
    if (newWords.isNotEmpty) 'says: ${newWords.join(' / ')}',
    if (channels.isNotEmpty) 'calls: ${channels.toSet().join(', ')}',
  ];
  return parts.join('; ');
}

String _diff(String a, String b) {
  final x = a.split(' '), y = b.split(' ');
  return [for (var i = 0; i < x.length; i++) if (x[i] != y[i]) y[i]].join(' ');
}

/// Records the phone's channels the screen calls, on top of the harness's
/// silent answers.
List<String> _recordChannels(WidgetTester tester) {
  final seen = <String>[];
  tester.binding.defaultBinaryMessenger.allMessagesHandler =
      (String channel, MessageHandler? handler, ByteData? message) async {
    if (!channel.startsWith('flutter/') || channel == 'flutter/platform') {
      if (message != null) {
        try {
          final call = const StandardMethodCodec().decodeMethodCall(message);
          seen.add('$channel ${call.method}');
        } catch (_) {
          try {
            final call = const JSONMethodCodec().decodeMethodCall(message);
            seen.add('$channel ${call.method}');
          } catch (_) {
            seen.add(channel);
          }
        }
      }
    }
    if (channel.startsWith('dev.flutter.pigeon.')) {
      return const StandardMessageCodec().encodeMessage(<Object?>[null]);
    }
    // The app's folders, as a phone has them: favourites, playlists and a
    // screenshot write there.
    if (channel == 'plugins.flutter.io/path_provider' &&
        message != null &&
        const StandardMethodCodec().decodeMethodCall(message).method ==
            'getApplicationDocumentsDirectory') {
      return const StandardMethodCodec()
          .encodeSuccessEnvelope(_scratch.path);
    }
    if (handler != null) return handler(message);
    return null;
  };
  return seen;
}

final Directory _scratch = Directory.systemTemp.createTempSync('player_fn');

Future<void> _openMore(WidgetTester tester) async {
  playerContainer!.read(playerControllerProvider.notifier).openMoreMenu();
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  // Real fonts: a row's overflow is the real one, not the test font's
  // (every glyph a full em wide).
  setUpAll(() async => loadPlayerFonts());
  tearDownAll(() {
    final out = Platform.environment['FUNCTIONS_OUT'];
    if (out != null) {
      File(out).writeAsStringSync(
          '${_log.map((l) => l.length > 300 ? '${l.substring(0, 300)}…' : l).join('\n')}\n');
    }
  });

  // ⋮'s tiles, upright (where ♪ and CC are tiles too): label → what it
  // must do.
  final tiles = <String, void Function(String effect)>{
    'audioTrack': (e) => expect(e, contains('Audio delay')),
    'subtitle': (e) => expect(e, contains('panel=subtitle')),
    'playingQueue': (e) => expect(e, contains('PlayingQueueSheet')),
    'aspectRatioMenu': (e) => expect(e, contains('Aspect ratio')),
    'displaySettings': (e) => expect(e, contains('DisplaySettingsSheet')),
    'bookmark': (e) => expect(e, contains('Bookmark')),
    'cut': (e) => expect(e, contains('CutSheet')),
    'favourite': (e) => expect(e, contains('avourite')),
    'addToPlaylistMenu': (e) => expect(e, contains('laylist')),
    'information': (e) => expect(e, contains('Location')),
    'share': (e) => expect(e, contains('share')),
    'tutorial': (e) => expect(e, contains('GesturesHelp')),
  };

  for (final entry in tiles.entries) {
    testWidgets('⋮ ${entry.key} does what it says', (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
      final channels = _recordChannels(tester);
      await _openMore(tester);
      final s = AppStrings.of(tester.element(find.byType(PlayerScreen)));
      final label = switch (entry.key) {
        'audioTrack' => s.audioTrack,
        'subtitle' => s.subtitle,
        'playingQueue' => s.playingQueue,
        'aspectRatioMenu' => s.aspectRatioMenu,
        'displaySettings' => s.displaySettings,
        'bookmark' => s.bookmark,
        'cut' => s.cut,
        'favourite' => s.favourite,
        'addToPlaylistMenu' => s.addToPlaylistMenu,
        'information' => s.information,
        'share' => s.share,
        _ => s.tutorial,
      };
      final tile = find.byWidgetPredicate(
          (w) => w is PanelTile && w.label == label);
      expect(tile, findsOneWidget, reason: '⋮ has no "$label" tile');
      final e = await _effect(tester, tile, channels);
      _log.add('⋮ ${entry.key}: ${e.isEmpty ? 'NOTHING' : e}');
      expect(e, isNotEmpty, reason: '⋮ "$label" did nothing');
      entry.value(e);
      await leavePlayer(tester);
    });
  }

  // The More page's rows.
  final rows = <String, void Function(String effect)>{
    'kidsLock': (e) => expect(e, contains('kids=true')),
    'tabTransfer': (e) => expect(e, isNotEmpty),
    'networkStream': (e) => expect(e, contains('NetworkStream')),
    'subtitleDelayMenu': (e) => expect(e, isNotEmpty),
    'skipMarkers': (e) => expect(e, contains('SkipMarkers')),
    'customSpeed': (e) => expect(e, isNotEmpty),
    'pmDecoder': (e) => expect(e, contains('decoder=true')),
    'pmPip': (e) => expect(e, isNotEmpty),
    'settingsTitle': (e) => expect(e, contains('Settings')),
    'faq': (e) => expect(e, contains('Help')),
    'pmCheckUpdates': (e) => expect(e, contains('Update')),
  };

  for (final entry in rows.entries) {
    testWidgets('⋮ More › ${entry.key} does what it says', (tester) async {
      await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
      final channels = _recordChannels(tester);
      await _openMore(tester);
      final more = find.byWidgetPredicate(
          (w) => w is PanelTile && w.icon == Icons.chevron_right_rounded);
      await tester.ensureVisible(more);
      await tester.pump();
      await tester.tap(more);
      await _settle(tester);
      final s = AppStrings.of(tester.element(find.byType(PlayerScreen)));
      final title = switch (entry.key) {
        'kidsLock' => s.kidsLock,
        'tabTransfer' => s.tabTransfer,
        'networkStream' => s.networkStream,
        'subtitleDelayMenu' => s.subtitleDelayMenu,
        'skipMarkers' => s.skipMarkers,
        'customSpeed' => s.customSpeed,
        'pmDecoder' => s.pmDecoder,
        'pmPip' => s.pmPip,
        'settingsTitle' => s.settingsTitle,
        'faq' => s.faq,
        _ => s.pmCheckUpdates,
      }
          .replaceAll('\n', ' ');
      final row = find.byWidgetPredicate(
          (w) => w is PanelRow && w.title == title);
      if (entry.key == 'pmPip' && row.evaluate().isEmpty) {
        // Only while the bottom row's PiP button is hidden (Customise
        // Items); it is there by default.
        final c = playerContainer!.read(playerControllerProvider.notifier);
        c.closePanel();
        c.showControls();
        await _settle(tester);
        expect(find.byIcon(Icons.picture_in_picture_alt_outlined), findsWidgets,
            reason: 'PiP is neither on the More page nor on the controls');
        _log.add('More pmPip: not on the page (the controls carry PiP)');
        await leavePlayer(tester);
        return;
      }
      expect(row, findsOneWidget, reason: 'More has no "$title" row');
      final e = await _effect(tester, row, channels);
      _log.add('More ${entry.key}: ${e.isEmpty ? 'NOTHING' : e}');
      expect(e, isNotEmpty, reason: 'More "$title" did nothing');
      entry.value(e);
      await leavePlayer(tester);
    });
  }

  // The shortcut row, open, both ways round.
  for (final landscape in [false, true]) {
    final o = landscape ? 'sideways' : 'upright';
    for (final item in ShortcutItem.available()) {
      testWidgets('$o: the ${item.name} shortcut does what it says',
          (tester) async {
        await pumpPlayer(tester,
            phone: _phone, landscape: landscape, lang: 'en');
        final channels = _recordChannels(tester);
        final c = playerContainer!.read(playerControllerProvider.notifier);
        c.showControls();
        if (!_state().shortcutsExpanded) c.toggleShortcutsExpanded();
        await _settle(tester);
        final key = find.byKey(ValueKey(item.name), skipOffstage: false);
        // The open row is a list that scrolls sideways: build its far end.
        if (key.evaluate().isEmpty) {
          await tester.scrollUntilVisible(key, 120,
              scrollable: find
                  .descendant(
                      of: find.byType(ListView), matching: find.byType(Scrollable))
                  .first);
        }
        expect(key, findsWidgets, reason: 'no ${item.name} on the row');
        final e = await _effect(tester, key, channels);
        _log.add('$o shortcut ${item.name}: ${e.isEmpty ? 'NOTHING' : e}');
        expect(e, isNotEmpty, reason: 'the ${item.name} shortcut did nothing');
        switch (item) {
          case ShortcutItem.nightMode:
            expect(e, contains('night=true'));
          case ShortcutItem.customiseItems:
            expect(e, contains('panel=customise'));
          case ShortcutItem.shuffle:
            expect(e, contains('shuffle=true'));
          case ShortcutItem.loop:
            expect(e, contains('loop='));
          case ShortcutItem.mute:
            expect(e, contains('mute=true'));
          case ShortcutItem.sleepTimer:
            expect(e, contains('sleep=true'));
          case ShortcutItem.abRepeat:
            expect(e, contains('ABRepeatBar'));
          case ShortcutItem.audioEffect:
          case ShortcutItem.equalizer:
            expect(e, contains('AudioEffectSheet'));
          case ShortcutItem.playbackSpeed:
            expect(e, contains('panel=speed'));
          case ShortcutItem.backgroundPlay:
            expect(e, contains('bg='));
          case ShortcutItem.mirrorMode:
            expect(e, contains('mirror=true'));
          case ShortcutItem.verticalFlip:
            expect(e, contains('flip=true'));
          case ShortcutItem.screenshot:
            // The picture goes to the gallery (MediaStore), the app's own
            // folder only where that fails.
            expect(e, contains('saveImage'));
          case ShortcutItem.screenRotation:
            expect(e, contains('setPreferredOrientations'));
        }
        await leavePlayer(tester);
      });
    }
  }

  // A vault film's or a protected film's picture is never copied out by
  // the Screenshot shortcut (27 Nov 2026: it saved a plain PNG of it).
  for (final secure in [false, true]) {
    testWidgets(
        'no screenshot of a ${secure ? 'protected' : 'vault'} film',
        (tester) async {
      await pumpPlayer(tester,
          phone: _phone,
          landscape: true,
          lang: 'en',
          engine: FakePlayerService(),
          isPrivate: !secure,
          secureScreen: secure);
      final channels = _recordChannels(tester);
      final c = playerContainer!.read(playerControllerProvider.notifier);
      c.showControls();
      if (!_state().shortcutsExpanded) c.toggleShortcutsExpanded();
      await _settle(tester);
      final key = find.byKey(const ValueKey('screenshot'), skipOffstage: false);
      if (key.evaluate().isEmpty) {
        await tester.scrollUntilVisible(key, 120,
            scrollable: find
                .descendant(
                    of: find.byType(ListView), matching: find.byType(Scrollable))
                .first);
      }
      List<String> shots() => _scratch
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.contains('screenshot_'))
          .toList();
      final before = shots();
      final e = await _effect(tester, key, channels);
      final s = AppStrings.of(tester.element(find.byType(PlayerScreen)));
      expect(e, contains(s.plScreenshotOff));
      expect(e, isNot(contains('saveImage')));
      expect(e, isNot(contains('getApplicationDocumentsDirectory')));
      expect(shots(), before, reason: 'a picture of the film was written');
      await leavePlayer(tester);
    });
  }
}
