// A REOPEN BEGINS WHERE IT WAS ASKED TO — against the real media_kit and a
// real libmpv.
//
// 1.64.68 reopened the film at 00:00 after a change of quality, a step down,
// a reconnect: the start was written as libmpv's `start` property before
// Player.open(), and media_kit's open() stops the file that is playing first,
// whose `on_unload` hook resets `start` to `none`. Only an open with nothing
// playing kept it. media_kit writes [Media.start] back in its `on_load` hook,
// for the new file, so that is where the start goes now
// (MediaKitPlayerService.mediaFor).
//
// Needs libmpv and ffmpeg on the machine (stream-bench.yml installs both);
// skipped where either is missing.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/media_kit_player_service.dart';
import 'package:media_kit/media_kit.dart';

String? _libmpv() {
  for (final p in const [
    '/lib/x86_64-linux-gnu/libmpv.so.2',
    '/usr/lib/x86_64-linux-gnu/libmpv.so.2',
    '/lib/x86_64-linux-gnu/libmpv.so.1',
    '/usr/lib/x86_64-linux-gnu/libmpv.so.1',
  ]) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the start goes into the Media handed to media_kit', () {
    final m = MediaKitPlayerService.mediaFor('http://127.0.0.1/x',
        begin: const Duration(seconds: 754));
    expect(m.start, const Duration(seconds: 754));
    expect(MediaKitPlayerService.mediaFor('http://127.0.0.1/x').start, isNull);
  });

  final lib = _libmpv();
  final ffmpeg = Process.runSync('which', ['ffmpeg']).exitCode == 0;
  test('reopened while playing, the film begins at Media.start, not 00:00',
      () async {
    final dir = await Directory.systemTemp.createTemp('reopen');
    final film = '${dir.path}/film.mp4';
    // Three minutes, tiny, a keyframe every two seconds as on the ladder,
    // fragmented as the ladder is.
    final made = await Process.run('ffmpeg', [
      '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=24',
      '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
      '-t', '180', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '48',
      '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '64k',
      '-movflags', '+frag_keyframe+empty_moov+default_base_moof+global_sidx+cmaf+skip_trailer',
      film,
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');

    MediaKit.ensureInitialized(libmpv: lib);
    final p = Player(configuration: const PlayerConfiguration(vo: 'null'));
    await (p.platform as dynamic).setProperty('ao', 'null');
    Future<Duration> settled() async {
      await Future<void>.delayed(const Duration(seconds: 3));
      return p.state.position;
    }

    try {
      await p.open(Media(film));
      expect(await settled(), lessThan(const Duration(seconds: 10)));

      // What 1.64.68 did: the property, then open() — while playing.
      await (p.platform as dynamic).setProperty('start', '120');
      await p.open(Media(film));
      final viaProperty = await settled();
      // ignore: avoid_print
      print('reopen via the start property landed at ${viaProperty.inSeconds} s');

      // What it does now.
      await p.open(MediaKitPlayerService.mediaFor(film,
          begin: const Duration(seconds: 120)));
      final viaMedia = await settled();
      expect(viaMedia, greaterThanOrEqualTo(const Duration(seconds: 118)),
          reason: 'reopened at ${viaMedia.inSeconds} s');
      expect(viaMedia, lessThan(const Duration(seconds: 130)));

      // And again, as a second quality change would.
      await p.open(MediaKitPlayerService.mediaFor(film,
          begin: const Duration(seconds: 61)));
      final again = await settled();
      expect(again, greaterThanOrEqualTo(const Duration(seconds: 59)));
      expect(again, lessThan(const Duration(seconds: 70)));
    } finally {
      await p.dispose();
      await dir.delete(recursive: true);
    }
  },
      skip: lib == null || !ffmpeg ? 'needs libmpv and ffmpeg' : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
