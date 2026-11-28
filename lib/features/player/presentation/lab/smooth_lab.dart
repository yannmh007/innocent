import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/services/diagnostics/cpu_probe.dart';
import '../../../../core/services/diagnostics/playback_log.dart';
import '../../../../core/services/video_player/exo_engine.dart';
import '../shortcut_item.dart';
import '../widgets/player_ui.dart';

/// DEVICE LAB AND TEST LAB ONLY (`INNOCENT_LAB`) — the player's smoothness
/// as a viewer meets it, timed frame by frame.
///
/// WHY (27 Nov 2026). The owner, on 1.64.89: "⋮'s menu stutters and lags
/// when scrolled". A widget test counts what is rebuilt and repainted, but
/// cannot time a GPU; the emulator's GPU is not a phone's. This opens each
/// menu of the player on the phone itself — the film playing and paused —
/// flings its list up and down with a finger the app makes (the real drag
/// and fling path: pointer events into GestureBinding, as a touch screen
/// sends them), and writes one `LAB frames <state>/<menu>/<look> …` line a
/// moment ([CpuProbe.markEnd]): frames per second, build and raster
/// p50/p90/p99/worst, the frames over 16.7 ms (and over a frame at the
/// display's rate), and the threads' CPU over the same seconds.
///
/// A PLAN is steps separated by spaces, `STATE:MENU:LOOK[:SECONDS]`:
///  * STATE `play` or `pause`;
///  * MENU `more` (⋮), `morepage` (its "More ›" page), `cc`, `audio` (♪),
///    `queue`, `display`, `eq`, `sleep`, `bookmarks`, `shortcuts` (the
///    open shortcut row, scrolled sideways), `controls` (the controls up,
///    nothing scrolled), `film` (nothing over the film); any menu with
///    `-still` (`more-still`) is opened and timed without a scroll;
///  * LOOK a set of [PlayerUi] lab switches ([looks]): `base` is 1.64.89's
///    drawing, `now` the build's own;
///  * SECONDS of scrolling (5 by default; a still MENU is timed as long).
/// One play of every step, in order: the A/B is inside one run on one
/// phone, never across runs (skill device-labs).
///
/// A step `fn:more`, `fn:morepage` or `fn:shortcuts` taps every tile of ⋮,
/// every row of its More page or every shortcut of the open row in turn,
/// on the phone's own plugins, and writes what each did (`LAB fn …`: the
/// kinds of widget and the words that came, or NOTHING) — as
/// test/player_functions_test.dart does on a fake engine. Left out: Share
/// (Android's chooser takes the screen), picture-in-picture (it leaves the
/// player) and Screen Rotation (it turns the phone).
class SmoothLab {
  SmoothLab._();

  /// The player screen's, in a lab build: opens MENU (false when it could
  /// not), closes every menu and sheet, plays or pauses the film.
  static Future<bool> Function(String menu)? open;
  static Future<void> Function()? close;
  static Future<void> Function(bool play)? playing;

  /// The app's, in a lab build: the player opened again on a local file
  /// (the step `local`: libmpv, as a viewer's own video plays).
  static Future<void> Function(String path)? openFile;

  /// The app's, in a lab build: the lab's title opened again (the step
  /// `title`: back to ExoPlayer after `local`).
  static Future<void> Function()? openTitle;

  /// The player service's, in a lab build: libmpv's picture moved to a
  /// SurfaceView behind the window (the look `mpvsv`; `mpvembed` with
  /// vo=mediacodec_embed, [embed]); false when refused.
  static Future<bool> Function(bool embed)? mpvSurface;

  /// The player service's, in a lab build: libmpv's position events since
  /// the last ask (the controls over `mpvsv` drew 25 fps on the realme).
  static int Function()? mpvPositionEvents;

  /// The player screen's, in a lab build: one thing a viewer does (the
  /// step `do:WHAT`): `fit` `stretch` `crop` `original` (the screen
  /// mode), `zoom` (a pinch to 1.6x), `pan` (a drag of the zoomed picture),
  /// `mirror` `flip` `night` `filter` (Display's brightness; each again
  /// to put it back), `pause` `play`, `shot` (the Screenshot shortcut).
  /// Answers what it did, for the trail.
  static Future<String> Function(String what)? act;

  /// The app's, in a lab build: the player closed (the step `page`: the
  /// title's page behind it, scrolled).
  static Future<void> Function()? leave;

  /// The player service's, in a lab build: one of ♪'s items set as the
  /// menu sets it (`delay` ms, `stereo` 0-2, `night` 0/1, `off` 0/1,
  /// `gain` × 100) — the step `fn:audio` (P4 on real phones, 28 Nov 2026).
  static Future<void> Function(String item, int value)? audio;

  /// The default plan: ⋮ in every look, playing then paused; the other
  /// menus and the controls in the two that count.
  static const String defaultPlan =
      'play:film:base:4 play:film:now:4 '
      'play:controls:base:3 play:controls:now:3 '
      'play:more:base play:more:noink play:more:nomask play:more:rb '
      'play:more:notick play:more:now '
      'pause:more:base pause:more:now '
      'play:morepage:base play:morepage:now '
      'play:cc:base play:cc:now play:audio:base play:audio:now '
      'play:display:base play:display:now play:queue:base play:queue:now '
      'play:shortcuts:base:3 play:shortcuts:now:3 '
      'play:more:now play:more:base';

  /// The looks a step can ask for: each sets [PlayerUi]'s lab switches.
  /// `base`: the halo blurred three times (1, 3, 10; two since 27 Nov), the full-panel fade
  /// mask, no layer of its own for a list or a bar, the screen rebuilt on
  /// every position tick — 1.64.89. The others change one thing of it.
  /// `now`: the build's own choices.
  static const Map<String, Map<String, Object>> looks = {
    'base': {
      'ink': 'blur3', 'mask': true, 'rb': false, 'tick': true, 'stretch': true
    },
    // Everything of `now` but the lists' stretch at their ends.
    'nostretch': {'stretch': false},
    'noink': {'ink': 'none', 'rb': false, 'tick': true, 'stretch': true},
    'rim': {'ink': 'rim', 'rb': false, 'tick': true, 'stretch': true},
    'nomask': {
      'ink': 'blur3', 'mask': false, 'rb': false, 'tick': true, 'stretch': true
    },
    'rb': {'ink': 'blur3', 'rb': true, 'tick': true, 'stretch': true},
    'notick': {'ink': 'blur3', 'rb': false, 'tick': false, 'stretch': true},
    // Everything of `now` but the halo: 1.64.89's three blurs.
    'ink3': {'ink': 'blur3', 'stretch': true},
    'now': <String, Object>{},
    // P1, the film's own cost. Since 28 Nov 2026 the build's own (`now`)
    // puts an ExoPlayer film on Android's own SurfaceView under Flutter's
    // see-through surface (PlayerWindow.kt; ExoStreamEngine's film
    // surface); the looks draw it another way ([_native]):
    //  `tex`    the film kept on Flutter's texture, as 1.64.90 drew it;
    //  `sv`     the same as `now` (plans written before 28 Nov);
    //  `sched`  ExoPlayer's dynamic scheduling (the film opened again);
    //  `opaque` the window as 1.64.90 had it (Flutter's surface opaque: the
    //           Activity made again once, the film on the texture) — what
    //           the see-through surface costs a screen;
    //  `…prof`  the same, the main thread profiled message by message
    //           (`LAB main …`; the profiling itself costs a little).
    'tex': {'tex': true},
    'sv': <String, Object>{},
    'sched': {'sched': true},
    'opaque': {'opaque': true},
    'nowprof': {'prof': true},
    'svprof': {'prof': true},
    'texprof': {'tex': true, 'prof': true},
    // libmpv (after `local`): its picture on a SurfaceView behind the
    // see-through window, rendered there by libmpv itself — by GL
    // (`mpvsv`, vo=gpu) or by MediaCodec straight into it (`mpvembed`,
    // vo=mediacodec_embed, no GL).
    'mpvsv': {'mpvsv': true},
    'mpvsvprof': {'mpvsv': true, 'prof': true},
    'mpvembed': {'mpvembed': true},
    'mpvembedprof': {'mpvembed': true, 'prof': true},
  };

  // ── The film drawn another way (P1) ────────────────────────────────────
  static const MethodChannel _lab = MethodChannel('innocent/lab');
  static bool _opaque = false;
  static bool _sched = false;

  /// Puts the film's surface, the window and ExoPlayer's scheduling as
  /// [look] asks (each the build's own unless named).
  static Future<void> _native(Map<String, Object> look) async {
    final tex = look['tex'] == true;
    final opaque = look['opaque'] == true;
    final sched = look['sched'] == true;
    final exo = ExoEngine.labLatest;
    // libmpv on a SurfaceView of this Activity (`mpvsv`, `mpvembed`): the
    // window and ExoPlayer's switches stay as they are.
    if (tex != ExoEngine.labTexture.value && !_mpvSv) {
      ExoEngine.labTexture.value = tex;
      PlaybackLog.add('LAB native: the film ${tex ? 'kept on the texture' : 'free for its own surface'}');
      await _wait(1500);
    }
    if (opaque != _opaque && !_mpvSv) {
      final ok = await _lab.invokeMethod<bool>('opaque', <String, Object?>{'on': opaque}) ?? false;
      _opaque = opaque;
      PlaybackLog.add('LAB native: the window ${opaque ? 'opaque (1.64.90)' : 'see-through'} '
          '(${ok ? 'recreated' : 'unchanged'})');
      // The Activity comes back on the cached engine: its view, the
      // surface, the first frames.
      await _wait(4500);
      await playing?.call(true);
      await _wait(1000);
    }
    if (sched != _sched && !_mpvSv) {
      final ok = await exo?.labSched(sched) ?? false;
      _sched = sched;
      PlaybackLog.add('LAB native: dynamic scheduling ${sched ? 'on' : 'off'} '
          '(${ok ? 'the film opened again' : 'no ExoPlayer'})');
      await _wait(5000);
    }
    // libmpv's picture on a SurfaceView: one way (the last steps of a
    // plan; the app closes after) — `mpvsv` (GL) then `mpvembed`
    // (MediaCodec) may follow each other: a new SurfaceView each.
    final embed = look['mpvembed'] == true;
    if ((look['mpvsv'] == true || embed) && (!_mpvSv || embed != _mpvEmbed)) {
      final ok = await mpvSurface?.call(embed) ?? false;
      _mpvSv = _mpvSv || ok;
      if (ok) _mpvEmbed = embed;
      PlaybackLog.add('LAB native: libmpv on a SurfaceView, '
          '${embed ? 'mediacodec_embed' : 'gpu'} (${ok ? 'on' : 'refused'})');
      await _wait(2500);
    }
    if (exo != null && !_mpvSv) {
      final st = await exo.stats();
      final win = await _lab.invokeMethod<String>('window');
      PlaybackLog.add('LAB native: the film on ${st['film'] ?? '?'}, window $win');
    }
  }

  static bool _mpvSv = false;
  static bool _mpvEmbed = false;

  static bool _running = false;

  /// Runs [plan] (or [defaultPlan] for an empty or "1" plan).
  static Future<void> run(String plan) async {
    if (!const bool.fromEnvironment('INNOCENT_LAB') || _running) return;
    _running = true;
    try {
      final steps = (plan.trim().isEmpty || plan.trim() == '1'
              ? defaultPlan
              : plan)
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList();
      PlaybackLog.add('LAB smooth: ${steps.length} steps, '
          'display ${CpuProbe.refreshRate.round()} Hz');
      for (final step in steps) {
        if (step == 'local' || step.startsWith('local:')) {
          if (!await _playLocal(step.length > 6 ? step.substring(6) : '')) break;
          continue;
        }
        if (step == 'title') {
          final o = openTitle;
          if (o == null) {
            PlaybackLog.add('LAB title: nothing opens it');
            break;
          }
          await close?.call();
          await o();
          // The film's page, its start, the first rung settled.
          await _wait(14000);
          PlaybackLog.add('LAB title: playing again');
          continue;
        }
        final p = step.split(':');
        if (p.length == 2 && p[0] == 'fn') {
          await _functions(p[1]);
          continue;
        }
        if (p.length == 2 && p[0] == 'do') {
          final done = await act?.call(p[1]) ?? 'no player';
          PlaybackLog.add('LAB do ${p[1]}: $done');
          // The film's surface follows (a move waits for a first frame).
          await _wait(2500);
          continue;
        }
        if (p.length == 2 && p[0] == 'shot') {
          // run.sh takes the screen (adb screencap: the display, the film's
          // own surface included) when it reads this line.
          final exo = ExoEngine.labLatest;
          final st = exo == null ? const <String, Object?>{} : await exo.stats();
          final rect = st['filmRect'];
          // In step with run.sh (P1-E9: a screencap taken by polling can
          // fall behind): it writes lab_shot_ack once it has the screen.
          final dir = await getExternalStorageDirectory();
          final ack = File('${dir?.path}/lab_shot_ack');
          try {
            if (ack.existsSync()) ack.deleteSync();
          } catch (_) {}
          await _wait(800);
          PlaybackLog.add('LAB shot ${p[1]} film=${st['film'] ?? '-'}'
              '${rect == null ? '' : ' at $rect'}');
          final until = DateTime.now().add(const Duration(seconds: 15));
          var taken = false;
          while (DateTime.now().isBefore(until)) {
            await _wait(250);
            if (ack.existsSync()) {
              taken = true;
              break;
            }
          }
          if (!taken) PlaybackLog.add('LAB shot ${p[1]}: no ack from run.sh');
          continue;
        }
        if (p.length >= 2 && p[0] == 'page') {
          await _page(p[1], p.length > 2 ? (double.tryParse(p[2]) ?? 6) : 6.0);
          continue;
        }
        if (p.length >= 2 && p[0] == 'pinch') {
          await _pinch(p[1], p.length > 2 ? (double.tryParse(p[2]) ?? 4) : 4.0);
          continue;
        }
        if (p.length < 3) continue;
        final seconds = p.length > 3 ? (double.tryParse(p[3]) ?? 5) : 5.0;
        await _step(p[0], p[1], p[2], seconds);
      }
      PlayerUi.labReset();
      await _native(const <String, Object>{});
      PlaybackLog.add('LAB smooth: done');
    } catch (e) {
      PlaybackLog.add('LAB smooth: stopped ($e)');
    } finally {
      _running = false;
    }
  }

  /// A minute of the film playing now, copied from the local proxy into a
  /// file, and the player opened on it: what follows is libmpv on a local
  /// file (P1: MX's 26 % was a local film). False when there is none.
  ///
  /// [how] (P1-E4, 28 Nov 2026: P1-E3's copy played sound and no picture):
  /// '' the first fragments as one byte range; `whole` the whole rung, one
  /// read; `lab` no copy — the film run.sh made with ffmpeg and pushed as
  /// `lab_fresh.mp4` into the app's external files folder.
  static Future<bool> _playLocal(String how) async {
    final url = ExoEngine.labLatest?.labUrl;
    if (url == null && how != 'lab') {
      PlaybackLog.add('LAB local: no film to copy');
      return false;
    }
    await close?.call();
    // ExoPlayer's own switches off; the window stays as it is — a second
    // switch of the window's mode stopped the film on the emulator (run
    // 46019884853: after the Activity was made again, play went to libmpv),
    // so a plan changes it once.
    await _native(<String, Object>{'opaque': _opaque});
    final String? path;
    if (how == 'lab') {
      final dir = await getExternalStorageDirectory();
      final f = File('${dir?.path}/lab_fresh.mp4');
      path = dir != null && f.existsSync() ? f.path : null;
      PlaybackLog.add(path == null
          ? 'LAB local: no lab_fresh.mp4'
          : 'LAB local: the lab\'s own file, ${f.lengthSync() ~/ 1024} KB');
    } else {
      path = await _localCopy(url!, whole: how == 'whole');
    }
    if (path == null) return false;
    final open = openFile;
    if (open == null) {
      PlaybackLog.add('LAB local: nothing opens a file');
      return false;
    }
    await open(path);
    // The new player screen, libmpv's first frames, the film settled.
    await _wait(9000);
    PlaybackLog.add('LAB local: playing $path');
    return true;
  }

  /// The tallest rung up to 720p of [master]: its init and segments up to
  /// [seconds] of film, one after another in one file (fMP4 or MPEG-TS
  /// concatenate). Null when encrypted or unreadable.
  static Future<String?> _localCopy(String master,
      {int seconds = 75, bool whole = false}) async {
    final client = HttpClient();
    try {
      Future<String> text(Uri u) async {
        final rq = await client.getUrl(u);
        final rs = await rq.close();
        return rs.transform(utf8.decoder).join();
      }

      final m = Uri.parse(master);
      final mText = await text(m);
      var pick = m;
      var best = 0;
      final lines = mText.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trim();
        if (!l.startsWith('#EXT-X-STREAM-INF')) continue;
        final r = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(l);
        final h = r == null ? 0 : int.parse(r.group(2)!);
        var j = i + 1;
        while (j < lines.length &&
            (lines[j].trim().isEmpty || lines[j].trim().startsWith('#'))) {
          j++;
        }
        if (j < lines.length && h <= 720 && h > best) {
          best = h;
          pick = m.resolve(lines[j].trim());
        }
      }
      if (mText.contains('TYPE=AUDIO')) {
        PlaybackLog.add('LAB local: the ladder has separate audio (not copied)');
      }
      final media = identical(pick, m) ? mText : await text(pick);
      if (media.contains('#EXT-X-KEY') && !media.contains('METHOD=NONE')) {
        PlaybackLog.add('LAB local: the rung is encrypted, no local file');
        return null;
      }
      // The ladder's rungs are one CMAF file each, read by byte ranges
      // (hls_ladder.dart: the init, then each fragment's @offset): the
      // copy is one range, the init and the first fragments. Separate
      // segment files are joined one after another.
      Uri? init;
      int? initEnd;
      final segs = <Uri>[];
      final ranges = <(int, int)>[];
      var total = 0.0;
      double? dur;
      (int, int)? range;
      for (final raw in media.split('\n')) {
        final l = raw.trim();
        if (l.startsWith('#EXT-X-MAP')) {
          final u = RegExp(r'URI="([^"]+)"').firstMatch(l);
          if (u != null) init = pick.resolve(u.group(1)!);
          final b = RegExp(r'BYTERANGE="(\d+)@(\d+)"').firstMatch(l);
          if (b != null) initEnd = int.parse(b.group(2)!) + int.parse(b.group(1)!);
        } else if (l.startsWith('#EXTINF:')) {
          dur = double.tryParse(l.substring(8).split(',').first);
        } else if (l.startsWith('#EXT-X-BYTERANGE:')) {
          final b = RegExp(r'(\d+)@(\d+)').firstMatch(l);
          if (b != null) range = (int.parse(b.group(2)!), int.parse(b.group(1)!));
        } else if (l.isNotEmpty && !l.startsWith('#')) {
          if (total >= seconds) break;
          segs.add(pick.resolve(l));
          if (range != null) ranges.add(range);
          range = null;
          total += dur ?? 0;
          dur = null;
        }
      }
      if (segs.isEmpty) {
        PlaybackLog.add('LAB local: no segments');
        return null;
      }
      final dir = await getTemporaryDirectory();
      final out = File('${dir.path}/lab_local_${best}p${whole ? '_whole' : ''}.'
          '${init != null ? 'mp4' : 'ts'}');
      final sink = out.openWrite();
      final oneFile = ranges.length == segs.length &&
          segs.every((u) => u == segs.first) &&
          (init == null || init == segs.first);
      if (oneFile) {
        final last = ranges.last;
        final rq = await client.getUrl(segs.first);
        // `whole`: the rung's file as it is, every fragment (P1-E1's copy
        // that played was the whole file, read 38 times over).
        if (!whole) {
          rq.headers.set(HttpHeaders.rangeHeader,
              'bytes=0-${last.$1 + last.$2 - 1}');
        }
        final rs = await rq.close();
        PlaybackLog.add('LAB local: ${rs.statusCode}, '
            '${rs.headers.value(HttpHeaders.contentRangeHeader) ?? 'no range'}, '
            'length ${rs.contentLength}');
        await sink.addStream(rs);
      } else {
        for (final u in <Uri>[if (init != null) init, ...segs]) {
          final rq = await client.getUrl(u);
          final rs = await rq.close();
          await sink.addStream(rs);
        }
      }
      await sink.close();
      PlaybackLog.add('LAB local: ${oneFile ? '${whole ? 'whole file' : 'one range'}, init ${initEnd ?? 0} B, ' : ''}'
          '${segs.length} segments, '
          '${total.round()} s of ${best}p, ${(await out.length()) ~/ 1024} KB');
      return out.path;
    } catch (e) {
      PlaybackLog.add('LAB local: copy failed ($e)');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _wait(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// The step `page:LOOK[:SECONDS]`: the player left for the title's page
  /// behind it, which is flung up and down and timed (`LAB frames
  /// page/LOOK`) — what the window's see-through surface costs a screen
  /// that is not the player (`opaque` beside `now`). `title` brings the
  /// film back.
  static Future<void> _page(String look, double seconds) async {
    await close?.call();
    final l = leave;
    if (l == null) {
      PlaybackLog.add('LAB frames page/$look: nothing leaves the player');
      return;
    }
    await l();
    await _wait(2500);
    final asked = looks[look] ?? const <String, Object>{};
    await _native(asked);
    final scroll = _findScrollable(horizontal: false);
    if (scroll == null) {
      PlaybackLog.add('LAB frames page/$look: nothing to scroll');
      return;
    }
    CpuProbe.markStart('page/$look');
    final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
    var up = true;
    while (DateTime.now().isBefore(end)) {
      await _fling(scroll, up: up);
      up = !up;
      await _wait(700);
    }
    if (CpuProbe.markEnd() == null) PlaybackLog.add('LAB frames page/$look: no window');
  }

  /// The step `pinch:LOOK[:SECONDS]`: the picture zoomed in and out by two
  /// fingers' worth of steps (the controller's pinch, 60 a second) while
  /// the film plays, timed (`LAB frames pinch/LOOK`): on its own surface
  /// each step moves a SurfaceView; on the texture Flutter scales it.
  static Future<void> _pinch(String look, double seconds) async {
    await close?.call();
    await _wait(400);
    final asked = looks[look] ?? const <String, Object>{};
    PlayerUi.labLook(asked);
    await _native(asked);
    await playing?.call(true);
    await _wait(900);
    CpuProbe.markStart('pinch/$look');
    final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
    var i = 0;
    while (DateTime.now().isBefore(end)) {
      // 30 steps up by 2 %, 30 down: 1.0 → 1.8 → 1.0 a second.
      await act?.call((i ~/ 30).isEven ? 'pinch+' : 'pinch-');
      i++;
      await _wait(16);
    }
    await act?.call('pinchend');
    if (CpuProbe.markEnd() == null) PlaybackLog.add('LAB frames pinch/$look: no window');
    await act?.call('fit');
  }

  static Future<void> _step(
      String state, String menu, String look, double seconds) async {
    final name = '$state/$menu/$look';
    await close?.call();
    await _wait(400);
    final asked = looks[look] ?? const <String, Object>{};
    PlayerUi.labLook(asked);
    await _native(asked);
    await playing?.call(state != 'pause');
    await _wait(900);
    // `more-still`: ⋮ open, nothing scrolled — what an open menu costs
    // while the film plays under it.
    final stillMenu = menu.endsWith('-still');
    final opened = stillMenu ? menu.substring(0, menu.length - 6) : menu;
    if (opened != 'film') {
      final ok = await open?.call(opened) ?? false;
      if (!ok) {
        PlaybackLog.add('LAB frames $name: could not open');
        return;
      }
    }
    // The menu in, its fade measured, the first frames of its film drawn.
    await _wait(900);
    final still = stillMenu || menu == 'film' || menu == 'controls';
    final scroll = still ? null : _findScrollable(horizontal: menu == 'shortcuts');
    if (!still && scroll == null) {
      PlaybackLog.add('LAB frames $name: nothing to scroll');
    }
    final prof = asked['prof'] == true;
    if (prof) await _lab.invokeMethod<bool>('profileStart');
    CpuProbe.markStart(name);
    final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
    if (menu == 'controls') {
      // The controls hide after 4 s: shown again every 3 s, as a viewer
      // who keeps touching would.
      while (DateTime.now().isBefore(end)) {
        await _wait(3000);
        await open?.call('controls');
      }
    } else if (scroll == null) {
      await _wait((seconds * 1000).round());
    } else {
      var up = true;
      while (DateTime.now().isBefore(end)) {
        await _fling(scroll, up: up);
        up = !up;
        await _wait(700);
      }
    }
    final line = CpuProbe.markEnd();
    if (line == null) PlaybackLog.add('LAB frames $name: no window');
    if (_mpvSv) {
      final n = mpvPositionEvents?.call();
      if (n != null) {
        PlaybackLog.add('LAB mpvpos $name: $n position events in '
            '${seconds.toStringAsFixed(0)} s (${(n / seconds).toStringAsFixed(1)}/s)');
      }
    }
    if (prof) {
      final main = await _lab.invokeMethod<String>('profileStop');
      PlaybackLog.add('LAB main $name: $main');
    }
  }

  /// The list the open menu scrolls: the last vertical (or horizontal)
  /// Scrollable laid out on screen — the menu is drawn over the player —
  /// preferring one with somewhere to go.
  static ({Rect rect, Axis axis})? _findScrollable({required bool horizontal}) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    final want = horizontal ? Axis.horizontal : Axis.vertical;
    ({Rect rect, Axis axis})? best;
    var bestRoom = false;
    void visit(Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        final s = e.state as ScrollableState;
        final ro = e.renderObject;
        if (axisDirectionToAxis(s.axisDirection) == want &&
            ro is RenderBox &&
            ro.attached &&
            ro.hasSize &&
            ro.size.width > 40 &&
            ro.size.height > 40) {
          final room = s.position.hasContentDimensions &&
              s.position.maxScrollExtent > 0;
          final at = ro.localToGlobal(Offset.zero) & ro.size;
          if (room || !bestRoom) {
            best = (rect: at, axis: want);
            bestRoom = room;
          }
        }
      }
      e.visitChildren(visit);
    }

    root.visitChildren(visit);
    return best;
  }

  static int _pointer = 7000;

  /// One finger's fling across the list: 28 moves 8 ms apart (a 120 Hz
  /// touch screen's rate) over 300 dp, then let go at speed.
  static Future<void> _fling(({Rect rect, Axis axis}) s, {required bool up}) async {
    final id = ++_pointer;
    final vertical = s.axis == Axis.vertical;
    final c = s.rect.center;
    final reach = (vertical ? s.rect.height : s.rect.width) * 0.3;
    final from = vertical
        ? Offset(c.dx, up ? c.dy + reach : c.dy - reach)
        : Offset(up ? c.dx + reach : c.dx - reach, c.dy);
    final total = vertical
        ? Offset(0, up ? -2 * reach : 2 * reach)
        : Offset(up ? -2 * reach : 2 * reach, 0);
    const moves = 28;
    final clock = Stopwatch()..start();
    final base = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
    Duration t() => base + clock.elapsed;
    final g = GestureBinding.instance;
    g.handlePointerEvent(PointerDownEvent(
        pointer: id, position: from, timeStamp: t(), kind: PointerDeviceKind.touch));
    var at = from;
    for (var i = 1; i <= moves; i++) {
      await _wait(8);
      final next = from + total * (i / moves);
      g.handlePointerEvent(PointerMoveEvent(
          pointer: id,
          position: next,
          delta: next - at,
          timeStamp: t(),
          kind: PointerDeviceKind.touch));
      at = next;
    }
    g.handlePointerEvent(PointerUpEvent(
        pointer: id, position: at, timeStamp: t(), kind: PointerDeviceKind.touch));
  }

  /// Taps the first widget [match] finds on screen (⋮'s "More ›" tile).
  static Future<bool> tap(bool Function(Widget w) match) async {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return false;
    Rect? hit;
    void visit(Element e) {
      if (hit != null) return;
      if (match(e.widget)) {
        final ro = e.renderObject;
        if (ro is RenderBox && ro.attached && ro.hasSize) {
          hit = ro.localToGlobal(Offset.zero) & ro.size;
          return;
        }
      }
      e.visitChildren(visit);
    }

    root.visitChildren(visit);
    if (hit == null) return false;
    // On screen first: ⋮'s last tiles and the open row's far end scroll.
    final el = _first(match);
    if (el != null) {
      try {
        await Scrollable.ensureVisible(el,
            duration: const Duration(milliseconds: 200), alignment: 0.5);
        await _wait(350);
        final ro = el.renderObject;
        if (ro is RenderBox && ro.attached && ro.hasSize) {
          hit = ro.localToGlobal(Offset.zero) & ro.size;
        }
      } catch (_) {}
    }
    final r = hit;
    if (r == null) return false;
    final id = ++_pointer;
    final g = GestureBinding.instance;
    final now = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
    g.handlePointerEvent(PointerDownEvent(
        pointer: id, position: r.center, timeStamp: now, kind: PointerDeviceKind.touch));
    await _wait(60);
    g.handlePointerEvent(PointerUpEvent(
        pointer: id,
        position: r.center,
        timeStamp: now + const Duration(milliseconds: 60),
        kind: PointerDeviceKind.touch));
    return true;
  }

  static Element? _first(bool Function(Widget w) match) {
    Element? found;
    void visit(Element e) {
      if (found != null) return;
      if (match(e.widget) && e.renderObject is RenderBox) {
        found = e;
        return;
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  static List<Element> _all(bool Function(Widget w) match) {
    final out = <Element>[];
    void visit(Element e) {
      if (match(e.widget)) out.add(e);
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return out;
  }

  /// What is on screen: the kinds of widget and the words.
  static ({Set<String> types, Set<String> words}) _look() {
    final types = <String>{};
    final words = <String>{};
    void visit(Element e) {
      types.add(e.widget.runtimeType.toString());
      final w = e.widget;
      if (w is Text && w.data != null) words.add(w.data!);
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return (types: types, words: words);
  }

  static const _kinds = [
    'Sheet', 'Dialog', 'Screen', 'Panel', 'Card', 'Bar', 'Overlay', 'Toast'
  ];

  /// Taps what [match] finds after [menu] is opened, and writes what came.
  static Future<void> _tryOne(
      String name, String menu, bool Function(Widget w) match) async {
    await close?.call();
    await _wait(500);
    if (!(await open?.call(menu) ?? false)) {
      PlaybackLog.add('LAB fn $name: could not open $menu');
      return;
    }
    await _wait(900);
    var before = _look();
    var tapped = await tap(match);
    if (!tapped && menu == 'shortcuts') {
      // The open row is a lazy list: its far end is not built until it is
      // scrolled to.
      for (final e in _all((w) => w is Scrollable)) {
        if (e is StatefulElement && e.state is ScrollableState) {
          final st = e.state as ScrollableState;
          if (axisDirectionToAxis(st.axisDirection) == Axis.horizontal &&
              st.position.hasContentDimensions) {
            st.position.jumpTo(st.position.maxScrollExtent);
          }
        }
      }
      await _wait(500);
      before = _look();
      tapped = await tap(match);
    }
    if (!tapped) {
      PlaybackLog.add('LAB fn $name: not on screen');
      return;
    }
    await _wait(1600);
    final after = _look();
    final shown = (after.types.difference(before.types).toList()..sort())
        .where((t) => _kinds.any(t.contains) && !t.startsWith('_'))
        .take(4)
        .toList();
    final said = after.words.difference(before.words).take(3).toList();
    final what = [
      if (shown.isNotEmpty) 'shows ${shown.join(', ')}',
      if (said.isNotEmpty) 'says ${said.join(' / ')}',
    ].join('; ');
    PlaybackLog.add('LAB fn $name: ${what.isEmpty ? 'NOTHING' : what}'
        .replaceAll('\n', ' '));
  }

  /// ♪'s items on the phone's own sound (P4): each set as the menu sets it,
  /// then what ExoPlayer's sound went through over the next 3 s — the
  /// shaper's frames (mono, swap, night), Night's gain, the delay, the
  /// audio track's switch, the volume and the boost (LoudnessEnhancer) —
  /// one `LAB fn audio/<item>` line each; then everything back.
  static Future<void> _audioChecks() async {
    final set = audio;
    final exo = ExoEngine.labLatest;
    if (set == null || exo == null) {
      PlaybackLog.add('LAB fn audio: ${set == null ? 'no hook' : 'no ExoPlayer'}');
      return;
    }
    Future<Map<String, Object?>> st() => exo.stats();
    num n(Map<String, Object?> m, String k) => (m[k] as num?) ?? -1;
    Future<void> one(String name, String item, int value) async {
      final a = await st();
      await set(item, value);
      await _wait(3000);
      final b = await st();
      PlaybackLog.add('LAB fn audio/$name: '
          'stereo=${b['stereo']} night=${b['night']} '
          'mono+${n(b, 'framesMono') - n(a, 'framesMono')} '
          'swap+${n(b, 'framesSwap') - n(a, 'framesSwap')} '
          'night+${n(b, 'framesNight') - n(a, 'framesNight')} '
          'gain=${n(b, 'gainDb').toStringAsFixed(1)}dB '
          'delay=${b['delayMs']}ms off=${b['audioOff']} '
          'vol=${n(b, 'volume').toStringAsFixed(2)} boost=${b['boostOn']}/${n(b, 'boostMb').round()}mB '
          'pos+${n(b, 'pos') - n(a, 'pos')}ms playing=${b['playing']}');
    }

    await one('mono', 'stereo', 1);
    await one('swap', 'stereo', 2);
    await one('stereo', 'stereo', 0);
    await one('night on', 'night', 1);
    await one('night off', 'night', 0);
    await one('delay +300', 'delay', 300);
    await one('delay -300', 'delay', -300);
    await one('delay 0', 'delay', 0);
    await one('disable', 'off', 1);
    await one('enable', 'off', 0);
    await one('boost 200', 'gain', 200);
    await one('boost 100', 'gain', 100);
  }

  static Future<void> _functions(String what) async {
    await close?.call();
    await _wait(500);
    if (what == 'audio') {
      await _audioChecks();
      return;
    }
    if (what == 'shortcuts') {
      for (final item in ShortcutItem.available()) {
        if (item == ShortcutItem.screenRotation) continue;
        await _tryOne('shortcut/${item.name}', 'shortcuts',
            (w) => w.key == ValueKey(item.name));
      }
      return;
    }
    final page = what == 'morepage';
    if (!(await open?.call(page ? 'morepage' : 'more') ?? false)) return;
    await _wait(900);
    final first = _first((w) => w is PanelTile);
    final s = first == null ? null : AppStrings.of(first);
    final skip = <String>{
      if (s != null) s.share,
      if (s != null) s.pmPip,
      if (s != null) s.moreOptions,
    };
    final names = page
        ? [
            for (final e in _all((w) => w is PanelRow))
              (e.widget as PanelRow).title,
          ]
        : [
            for (final e in _all((w) => w is PanelTile))
              (e.widget as PanelTile).label,
          ];
    PlaybackLog.add('LAB fn $what: ${names.length} to tap');
    for (final n in names) {
      if (skip.contains(n)) continue;
      await _tryOne(
          '$what/${n.replaceAll('\n', ' ')}',
          page ? 'morepage' : 'more',
          page
              ? (w) => w is PanelRow && w.title == n
              : (w) => w is PanelTile && w.label == n);
    }
  }
}
