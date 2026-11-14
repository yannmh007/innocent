// What libmpv itself says while a stream opens, through media_kit (14 Nov
// 2026): the evidence behind VideoPlayerService.firstPictureStream.
//
// A film served slowly from this machine, opened at a resume point as the
// app opens one through its local proxy. media_kit's open() says "not
// buffering" within a few tens of milliseconds — before a byte of the film
// has been served — and libmpv's video-params, which the service now takes
// for the first picture, come only once the bytes have arrived and a frame
// is decoded. Needs libmpv and ffmpeg (the Stream bench installs both, as
// for media_kit_reopen_start_test.dart).

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

/// Serves [file] with byte ranges, each answer held back by [delay]: a line
/// that answers late, as a far CDN does through the app's proxy.
Future<HttpServer> _slowServer(
    File file, Duration delay, void Function() firstByte) async {
  final bytes = await file.readAsBytes();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var sent = false;
  server.listen((HttpRequest req) async {
    await Future<void>.delayed(delay);
    var start = 0;
    var end = bytes.length - 1;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    final m =
        range == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    if (m != null) {
      start = int.parse(m.group(1)!);
      if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/${bytes.length}');
    }
    req.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = ContentType('video', 'mp4')
      ..contentLength = end - start + 1;
    if (!sent) {
      sent = true;
      firstByte();
    }
    try {
      req.response.add(bytes.sublist(start, end + 1));
      await req.response.close();
    } catch (_) {
      // libmpv closes a connection it no longer needs.
    }
  });
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final lib = _libmpv();
  final ffmpeg = Process.runSync('which', ['ffmpeg']).exitCode == 0;
  test('"not buffering" comes before a byte; video-params after the bytes',
      () async {
    final dir = await Directory.systemTemp.createTemp('first-picture');
    final film = File('${dir.path}/film.mp4');
    // Three minutes, small, a keyframe every two seconds, fragmented with an
    // index up front, as a 1-rung open film's copy is.
    final made = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=320x180:rate=24',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=48000',
      '-t',
      '180',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-g',
      '48',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-b:a',
      '64k',
      '-movflags',
      '+frag_keyframe+empty_moov+default_base_moof+global_sidx+cmaf+skip_trailer',
      film.path,
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');

    MediaKit.ensureInitialized(libmpv: lib);
    final p = Player(configuration: const PlayerConfiguration(vo: 'null'));
    await (p.platform as dynamic).setProperty('ao', 'null');
    // media_kit turns the video track off until a VideoController is made
    // (the app makes one); with no picture to draw, the decoder is told on.
    await (p.platform as dynamic).setProperty('vid', 'auto');
    final clock = Stopwatch();
    int? firstByteMs;
    final server = await _slowServer(film, const Duration(milliseconds: 700),
        () => firstByteMs = clock.elapsedMilliseconds);
    int? notBufferingMs;
    int? pictureMs;
    final subs = <StreamSubscription<Object?>>[
      p.stream.buffering.listen((b) {
        if (!b && clock.isRunning) notBufferingMs ??= clock.elapsedMilliseconds;
      }),
      p.stream.videoParams.listen((v) {
        if ((v.w ?? 0) > 0 && clock.isRunning) {
          pictureMs ??= clock.elapsedMilliseconds;
        }
      }),
    ];
    try {
      final url = 'http://127.0.0.1:${server.port}/film.mp4';
      clock.start();
      await p.open(MediaKitPlayerService.mediaFor(url,
          begin: const Duration(seconds: 120)));
      for (var i = 0; i < 100 && pictureMs == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // ignore: avoid_print
      print(
          'not buffering at $notBufferingMs ms, first byte at $firstByteMs ms, '
          'video-params at $pictureMs ms, position ${p.state.position.inSeconds} s');
      expect(notBufferingMs, isNotNull);
      expect(firstByteMs, isNotNull);
      expect(pictureMs, isNotNull, reason: 'no video-params in 10 s');
      expect(notBufferingMs!, lessThan(firstByteMs!),
          reason: '"not buffering" came before any byte: not a picture');
      expect(pictureMs!, greaterThan(firstByteMs!),
          reason: 'video-params came only with the bytes');
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      await p.dispose();
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  },
      skip: lib == null || !ffmpeg ? 'needs libmpv and ffmpeg' : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
