// The player screen laid out on the phones people have, both ways round, in
// the app's three languages and at the font sizes Android offers.
//
// What it holds: no control overflows, overlaps another or leaves the
// screen, on a 360 dp phone and up, in portrait and landscape, at font
// scale 1.0 and 1.3.
//
// Fonts: the real ones (test/support/player_harness.dart, loadPlayerFonts):
// Roboto and the icons from the Flutter SDK, Noto Sans Myanmar and Thai from
// test/fonts. Photographs of every state:
//   PLAYER_SHOTS=<out dir> flutter test test/player_layout_test.dart
// Narrow with SCENES=more,sleep; widen with LANGS=my,en,th SCALES=1.0,1.3.
// docs/player_ux_audit_2026_11.md says what it found.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/models/audio_track_info.dart';
import 'package:innocent/core/services/video_player/models/subtitle_track_info.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/widgets/more_menu_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_player_service.dart';
import 'support/player_harness.dart';

/// A state of the screen to photograph: what the viewer did to reach it.
class Scene {
  const Scene(this.name, this.reach, {this.portrait = true, this.landscape = true});
  final String name;
  final Future<void> Function(WidgetTester tester, PlayerController c,
      FakePlayerService svc) reach;
  final bool portrait;
  final bool landscape;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _tapIcon(WidgetTester tester, IconData icon) async {
  final f = find.byIcon(icon);
  await tester.ensureVisible(f.first);
  await tester.pump();
  await tester.tap(f.first, warnIfMissed: false);
  await _settle(tester);
}

final scenes = <Scene>[
  Scene('controls', (t, c, svc) async {}),
  Scene('expanded', (t, c, svc) async => _tapIcon(t, Icons.chevron_right)),
  Scene('more', (t, c, svc) async => _tapIcon(t, Icons.more_vert)),
  Scene('subtitle_panel', (t, c, svc) async {
    c.openSubtitleMenu();
    await _settle(t);
  }),
  Scene('audio_sheet', (t, c, svc) async => _tapIcon(t, Icons.music_note),
      portrait: false),
  Scene('subtitle_tracks', (t, c, svc) async {
    // A track chosen in the CC panel, then the panel again: the choice is
    // checked.
    c.openSubtitleMenu();
    await _settle(t);
    await t.tap(find.text('English').last, warnIfMissed: false);
    await _settle(t);
    c.openSubtitleMenu();
    await _settle(t);
  }),
  Scene('decoder', (t, c, svc) async {
    c.openDecoderDialog();
    await _settle(t);
  }),
  Scene('sleep', (t, c, svc) async {
    c.openSleepTimerDialog();
    await _settle(t);
  }),
  Scene('locked', (t, c, svc) async => _tapIcon(t, Icons.lock_open)),
  // An error that stopped the film: the card on the dimmed picture.
  Scene('error', (t, c, svc) async {
    await svc.pause();
    await _settle(t);
    svc.failWith('Failed to open https://stream.example/film/index.m3u8: '
        'connection reset by peer while reading the stream');
    await _settle(t);
  }),
  // One the film survived: the card at the top, the controls in reach.
  Scene('error_playing', (t, c, svc) async {
    await svc.play();
    await _settle(t);
    svc.failWith('Error parsing subtitle line 42: invalid timestamp');
    await _settle(t);
  }),
  Scene('loop_menu', (t, c, svc) async {
    await t.longPress(find.byIcon(Icons.skip_next).first, warnIfMissed: false);
    await _settle(t);
  }),
  Scene('speed_tap', (t, c, svc) async {
    await t.tap(find.byKey(const ValueKey('playbackSpeed')).first,
        warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 200));
  }),
  Scene('aspect_tap', (t, c, svc) async {
    await t.tap(find.byIcon(Icons.crop_landscape_outlined).first,
        warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 200));
  }),
];

/// Opens ⋮ and taps the row with [icon].
Future<void> _moreItem(WidgetTester t, IconData icon) async {
  await _tapIcon(t, Icons.more_vert);
  final f = find.descendant(
      of: find.byType(MoreMenuPanel), matching: find.byIcon(icon));
  await t.ensureVisible(f.first);
  await t.pump();
  await t.tap(f.first, warnIfMissed: false);
  await _settle(t);
}

final scenes2 = <Scene>[
  Scene('queue', (t, c, svc) => _moreItem(t, Icons.queue_music)),
  Scene('kids_lock', (t, c, svc) => _moreItem(t, Icons.child_care)),
  Scene('aspect_menu', (t, c, svc) => _moreItem(t, Icons.aspect_ratio)),
  Scene('display', (t, c, svc) => _moreItem(t, Icons.tune)),
  Scene('bookmarks', (t, c, svc) => _moreItem(t, Icons.bookmark_outline)),
  Scene('cut', (t, c, svc) => _moreItem(t, Icons.content_cut)),
  Scene('info', (t, c, svc) => _moreItem(t, Icons.info_outline)),
  Scene('help', (t, c, svc) => _moreItem(t, Icons.help_outline)),
  Scene('sub_delay', (t, c, svc) => _moreItem(t, Icons.subtitles_outlined)),
  Scene('skip_markers', (t, c, svc) => _moreItem(t, Icons.skip_next_outlined)),
  Scene('custom_speed', (t, c, svc) => _moreItem(t, Icons.speed)),
  Scene('ab_badge', (t, c, svc) async {
    c.cycleABRepeat();
    await svc.seek(const Duration(minutes: 14, seconds: 2));
    c.cycleABRepeat();
    await _settle(t);
  }),
  Scene('speed_indicator', (t, c, svc) async {
    await c.setSpeed(1.5);
    c.toggleControls();
    await _settle(t);
  }),
  Scene('volume', (t, c, svc) async {
    await c.onVolumeDelta(-0.25);
    await t.pump(const Duration(milliseconds: 100));
  }),
  Scene('seek_swipe', (t, c, svc) async {
    c.onSeekStart();
    c.onSeekUpdate(75);
    await t.pump(const Duration(milliseconds: 100));
  }),
  Scene('resume', (t, c, svc) async {
    // ignore: invalid_use_of_protected_member
    c.state = c.state.copyWith(
      resumeDialogOpen: true,
      resumeIsAskMode: true,
      pendingResumePosition: const Duration(minutes: 47, seconds: 3),
    );
    await _settle(t);
  }),
];

final _only = Platform.environment['SCENES']?.split(',').toSet();
// By default Burmese and Thai — the scripts that grow — at the largest
// common font size; the full matrix is LANGS=my,en,th SCALES=1.0,1.3.
final _langs = (Platform.environment['LANGS'] ?? 'my,th').split(',');
final _scales = (Platform.environment['SCALES'] ?? '1.3')
    .split(',')
    .map(double.parse)
    .toList();

/// Set in setUpAll: without the real fonts every glyph is a test-font box
/// a full em wide, and the overflows found would not be real ones.
var _realFonts = false;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _realFonts = await loadPlayerFonts();
  });

  for (final scene in [...scenes, ...scenes2]) {
    final only = _only;
    if (only != null && !only.contains(scene.name)) continue;
    for (final phone in phones) {
      for (final landscape in [false, true]) {
        if (landscape ? !scene.landscape : !scene.portrait) continue;
        for (final lang in _langs) {
          for (final scale in _scales) {
            final o = landscape ? 'land' : 'port';
            final tag = scale == 1.0 ? '' : '_x$scale';
            testWidgets('${scene.name} ${phone.name} $o $lang$tag',
                (tester) async {
              if (!_realFonts) {
                markTestSkipped('fonts not found (test/fonts, the SDK)');
                return;
              }
              final svc = FakePlayerService(
                audioTracks: const [
                  AudioTrackInfo(id: '1', title: 'Stereo', language: 'eng'),
                  AudioTrackInfo(id: '2', title: 'Commentary', language: 'eng'),
                ],
                subtitleTracks: const [
                  SubtitleTrackInfo(id: '1', language: 'mya', title: 'မြန်မာ'),
                  SubtitleTrackInfo(id: '2', language: 'eng', title: 'English'),
                ],
              );
              await pumpPlayer(tester,
                  phone: phone,
                  landscape: landscape,
                  lang: lang,
                  textScale: scale,
                  engine: svc);
              final c = playerContainer!.read(playerControllerProvider.notifier);
              await scene.reach(tester, c, svc);
              await shootPlayer(
                  tester, '${scene.name}/${phone.name}_${o}_$lang$tag');
              await leavePlayer(tester);
            });
          }
        }
      }
    }
  }
}
