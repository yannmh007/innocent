// A bench, run like a test: the test-only hooks are the point of it.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/network/foreground_stream.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_server.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/cmaf.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// The stream proxy over a line shaped like a Myanmar mobile connection.
///
/// Run by .github/workflows/stream-bench.yml after it has put `tc netem` on
/// the loopback interface — a round trip, a loss rate and a rate cap that a
/// phone actually sees. Locally, with no shaping, it only shows the software
/// ceiling.
///
/// For each lane count it plays a film of BENCH_MB through the real
/// StreamCacheServer the way libmpv reads it — one open-ended request,
/// consumed at the film's bitrate after a start-up buffer — and reports:
///
///   delivered   MB/s the proxy delivered while the player was waiting on it
///   first 512 KB  time to the first bytes the player can start reading
///   start       how long the black screen lasts: Play until 2 s of film is held
///   stalls      how many times playback ran dry, and for how long in all
///
///   BENCH_MB=48 BENCH_KBPS=6000 flutter test test_bench/stream_bench.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stream proxy: one connection against three', () async {
    HttpOverrides.global = null;
    final env = Platform.environment;
    final mb = int.tryParse(env['BENCH_MB'] ?? '') ?? 48;
    final kbps = int.tryParse(env['BENCH_KBPS'] ?? '') ?? 6000; // a 1080p film
    final temp = await Directory.systemTemp.createTemp('streambench');
    PathProviderPlatform.instance = _FakePaths(temp.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('mx_clone/media_scan'),
            (call) async => call.method == 'freeBytes' ? 64 * 1024 * 1024 * 1024 : null);

    final r = Random(5);
    final body = Uint8List.fromList(List<int>.generate(mb << 20, (_) => r.nextInt(256)));
    final film = body;
    // The rung a switch opens on, in the ladder's layout (ftyp, moov, sidx,
    // a fragment every 2 s): two minutes of a 720p rung, the usual climb.
    final switchKbps = int.tryParse(env['BENCH_SWITCH_KBPS'] ?? '') ?? 2500;
    final rung = FakeCmaf.build(
      fragments: 60,
      fragmentBytes: max(64 * 1024, switchKbps * 1000 ~/ 8 * 2),
    );
    // The Worker's part: ranges, 206, Content-Range. Bound to the loopback
    // ADDRESS of the shaped interface, so every byte crosses the netem queue.
    // A FIXED PORT when the workflow names one, so `tc` can shape this
    // server's traffic and nothing else: the proxy-to-player hop is inside
    // the phone and must not cross the shaped line.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4,
        int.tryParse(env['BENCH_PORT'] ?? '') ?? 0);
    server.listen((req) async {
      final res = req.response;
      final body = req.uri.path.endsWith('/rung.mp4') ? rung.bytes : film;
      var start = 0, end = body.length - 1;
      final h = req.headers.value(HttpHeaders.rangeHeader);
      if (h != null) {
        final spec = h.substring(6).split('-');
        start = int.parse(spec[0]);
        if (spec[1].isNotEmpty) end = min(int.parse(spec[1]), body.length - 1);
        res.statusCode = 206;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${body.length}');
      }
      res.headers.contentLength = end - start + 1;
      try {
        await res.addStream(Stream<List<int>>.value(Uint8List.sublistView(body, start, end + 1)));
        await res.close();
      } catch (_) {}
    });
    final upstream = 'http://127.0.0.1:${server.port}/film.mp4';

    final lines = <String>[];
    final laneCounts = (env['BENCH_LANES'] ?? '1,3')
        .split(',').map(int.parse).toList();
    for (final lanes in laneCounts) {
      StreamCacheServer.lanes = lanes;
      final id = 'bench-$lanes-${DateTime.now().microsecondsSinceEpoch}';
      final local = await StreamCacheServer.instance
          .localUrlFor(cacheId: id, upstream: upstream, refresh: () async => upstream);
      final res = await _play(local!, body.length, kbps);
      StreamCacheServer.instance.release(id);
      final line = 'lanes=$lanes  delivered ${res.mbps.toStringAsFixed(2)} MB/s  '
          'first 512 KB ${res.firstMs} ms  start ${res.startMs} ms  stalls ${res.stalls} '
          '(${(res.stalledMs / 1000).toStringAsFixed(1)} s)  '
          'film ${(body.length * 8 / kbps / 1000).toStringAsFixed(0)} s at $kbps kbps';
      lines.add(line);
      // ignore: avoid_print
      print(line);
    }
    // THE WARM START (StreamCacheServer.warmOpening): the viewer opens the
    // film's page, the opening is fetched over this same shaped line while
    // they read it, and only then do they press Play. `warm` is how long the
    // fetch took in the background; `start` is the black screen after the
    // tap, which is the number the warm-up exists to shrink.
    if (env['BENCH_WARM'] != '0') {
      final lanes = laneCounts.last;
      StreamCacheServer.lanes = lanes;
      // The rows above were a player streaming: what it last relayed still
      // counts as watching for a few seconds, and a warm-up never takes a
      // line a film is playing on.
      ForegroundStream.reset();
      final id = 'bench-warm-$lanes-${DateTime.now().microsecondsSinceEpoch}';
      final t = Stopwatch()..start();
      final warmed = await StreamCacheServer.instance
          .warmOpening(cacheId: id, upstream: upstream, refresh: () async => upstream);
      final warmMs = t.elapsedMilliseconds;
      final local = await StreamCacheServer.instance
          .localUrlFor(cacheId: id, upstream: upstream, refresh: () async => upstream);
      final res = await _play(local!, body.length, kbps);
      StreamCacheServer.instance.release(id);
      final line = 'warmed lanes=$lanes  warm ${warmed ? '$warmMs ms' : 'REFUSED'}  '
          'first 512 KB ${res.firstMs} ms  start ${res.startMs} ms  stalls ${res.stalls} '
          '(${(res.stalledMs / 1000).toStringAsFixed(1)} s)';
      lines.add(line);
      // ignore: avoid_print
      print(line);
    }
    // THE RUNG SWITCH (StreamCacheServer.warmSwitch): a climb or a menu
    // choice reopens the film on another copy at the same moment. `cold` is
    // the reopen as it was — index, then the fragment it seeks into, over
    // the line; `warm` fetches the new copy's next ten seconds first (the
    // old copy would be playing meanwhile) and then reopens. `picture` is
    // the frozen picture: the reopen until the fragment it seeks into and
    // the one after are held.
    if (env['BENCH_SWITCH'] != '0') {
      final lanes = laneCounts.last;
      StreamCacheServer.lanes = lanes;
      final rungUrl = 'http://127.0.0.1:${server.port}/rung.mp4';
      const at = Duration(seconds: 61);
      for (final warm in <bool>[false, true]) {
        final id = 'bench-switch-${warm ? 'warm' : 'cold'}-${DateTime.now().microsecondsSinceEpoch}';
        final local = await StreamCacheServer.instance
            .localUrlFor(cacheId: id, upstream: rungUrl, refresh: () async => rungUrl);
        var warmNote = '';
        if (warm) {
          final t = Stopwatch()..start();
          final w = await StreamCacheServer.instance.warmSwitch(id, at,
              limit: const Duration(seconds: 12), paceOver: 1.25);
          warmNote = '  warm ${t.elapsedMilliseconds} ms'
              '${w == null ? ' REFUSED' : w.complete ? ' (${w.kbps} kbps)' : ' NOT IN TIME (${w.kbps} kbps)'}';
        }
        final k = at.inSeconds ~/ 2; // the fragment holding 61 s: from 60 s
        final from = rung.fragmentStarts[k];
        final to = rung.fragmentStarts[k + 1] + rung.fragmentSizes[k + 1] - 1;
        final t = Stopwatch()..start();
        await _drain(local!, 0, rung.headEnd + 15);
        await _drain(local, from, to);
        final pictureMs = t.elapsedMilliseconds;
        StreamCacheServer.instance.release(id);
        final line = 'switch ${warm ? 'warm' : 'cold'} lanes=$lanes$warmNote  '
            'picture $pictureMs ms  ($switchKbps kbps rung)';
        lines.add(line);
        // ignore: avoid_print
        print(line);
      }
    }
    final out = env['BENCH_OUT'];
    if (out != null) File(out).writeAsStringSync('${lines.join('\n')}\n');
    await server.close(force: true);
    // The cache may still be writing its last record; a leftover temp
    // directory is not a result.
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  }, timeout: const Timeout(Duration(minutes: 20)));
}

/// Read bytes [a]..[b] of [url] to the end, as a player's closed range.
Future<void> _drain(String url, int a, int b) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$a-$b');
    await (await req.close()).drain<void>();
  } finally {
    c.close(force: true);
  }
}

class _Result {
  _Result(this.mbps, this.firstMs, this.startMs, this.stalls, this.stalledMs);
  final double mbps;
  final int firstMs;
  final int startMs;
  final int stalls;
  final int stalledMs;
}

/// A player in miniature: start after 2 s of film is buffered (ExoPlayer's
/// default is 2.5 s), then spend the film at its bitrate; when the buffer runs
/// dry it is a stall, and play resumes once 6 s are held again (the app's
/// `cache-pause-wait`). Reading is as fast as the proxy delivers — libmpv's
/// cache reads far ahead — so `delivered` is the line's real throughput.
Future<_Result> _play(String url, int total, int kbps) async {
  final bytesPerMs = kbps / 8; // kbit/s → bytes per millisecond
  final c = HttpClient();
  final sw = Stopwatch()..start();
  final req = await c.getUrl(Uri.parse(url));
  final resp = await req.close();
  var got = 0;
  var firstMs = -1;
  var startMs = -1;
  var playing = false;
  var playedBytes = 0.0;
  var lastTick = 0;
  var stalls = 0;
  var stalledMs = 0;
  var stallStart = 0;
  const startBuffer = 2000, resumeBuffer = 6000; // ms of film

  void tick() {
    final now = sw.elapsedMilliseconds;
    if (playing) {
      playedBytes += (now - lastTick) * bytesPerMs;
      if (playedBytes >= got && got < total) {
        playedBytes = got.toDouble();
        playing = false;
        stalls++;
        stallStart = now;
      }
    } else {
      final heldMs = (got - playedBytes) / bytesPerMs;
      final need = playedBytes == 0 ? startBuffer : resumeBuffer;
      if (heldMs >= need || got >= total) {
        if (playedBytes > 0) stalledMs += now - stallStart;
        if (startMs < 0) startMs = now;
        playing = true;
      }
    }
    lastTick = now;
  }

  final timer = Timer.periodic(const Duration(milliseconds: 50), (_) => tick());
  await for (final chunk in resp) {
    got += chunk.length;
    if (firstMs < 0 && got >= 512 * 1024) firstMs = sw.elapsedMilliseconds;
    tick();
  }
  final ms = sw.elapsedMilliseconds;
  timer.cancel();
  c.close(force: true);
  return _Result(got / 1048576 / (ms / 1000), firstMs, startMs, stalls, stalledMs);
}
