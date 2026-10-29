import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_server.dart';
import 'package:innocent/features/video_hub/data/rate_limited.dart';
import 'package:innocent/features/video_hub/domain/cmaf_index.dart';
import 'package:innocent/features/video_hub/domain/hls_ladder.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/cmaf.dart';

/// The ladder played as HLS through the proxy (StreamCacheServer.hlsUrlFor).
///
/// What must hold: the playlists name exactly the bytes of each rung's file;
/// every segment comes back byte for byte; reading ahead means the Worker is
/// asked a few times per film rather than once per two-second segment; a jump
/// is answered at once, not after the read it interrupted; and a film played
/// again comes from the phone.
class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// A Worker in miniature: one film per path, ranges answered with 206.
class _Worker {
  final Map<String, Uint8List> films = <String, Uint8List>{};
  late HttpServer server;
  final List<(String, int, int)> asked = <(String, int, int)>[];

  /// Each request as [asked] has it, and the client port it came on: one
  /// port, one connection (one handshake).
  final List<(String, int, int, int)> conns = <(String, int, int, int)>[];

  /// The next this many requests are told to slow down, as the Worker does
  /// past its ceiling: 429, `Retry-After: 2`.
  int limitNext = 0;
  int limited = 0;

  /// The line's pace: a wait before each 64 KB (0: as fast as it goes).
  int paceMs = 0;

  /// The next request starting at [stallFrom] sends [stallAfter] bytes and
  /// then nothing more, its connection held open — a connection stalled on
  /// a lossy line.
  int? stallFrom;
  int stallAfter = 0;

  String url(String name) => 'http://127.0.0.1:${server.port}/v/$name';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      if (limitNext > 0) {
        limitNext--;
        limited++;
        res.statusCode = 429;
        res.headers.set(HttpHeaders.retryAfterHeader, '2');
        await res.close();
        return;
      }
      final body = films[req.uri.pathSegments.last];
      if (body == null) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(req.headers.value('range') ?? '');
      final a = m == null ? 0 : int.parse(m.group(1)!);
      var b = m == null || m.group(2)!.isEmpty ? body.length - 1 : int.parse(m.group(2)!);
      if (b >= body.length) b = body.length - 1;
      asked.add((req.uri.pathSegments.last, a, b));
      conns.add((req.uri.pathSegments.last, a, b, req.connectionInfo?.remotePort ?? 0));
      res.statusCode = m == null ? 200 : 206;
      if (m != null) res.headers.set('content-range', 'bytes $a-$b/${body.length}');
      res.contentLength = b - a + 1;
      final stall = m != null && a == stallFrom ? stallAfter : null;
      if (stall != null) stallFrom = null;
      try {
        // A little at a time, as a line delivers it.
        for (var at = a; at <= b; at += 64 * 1024) {
          if (stall != null && at - a >= stall) {
            await Future<void>.delayed(const Duration(seconds: 30));
            break;
          }
          if (paceMs > 0) await Future<void>.delayed(Duration(milliseconds: paceMs));
          res.add(body.sublist(at, (at + 64 * 1024).clamp(0, b + 1)));
          await res.flush();
        }
        await res.close();
      } catch (_) {}
    });
  }
}

Future<(int, Uint8List)> _get(String url, {String? range}) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse(url));
    if (range != null) req.headers.set('range', range);
    final resp = await req.close();
    final out = BytesBuilder();
    await for (final chunk in resp) {
      out.add(chunk);
    }
    return (resp.statusCode, out.takeBytes());
  } finally {
    c.close(force: true);
  }
}

List<(int, int, String)> _segments(String playlist) => [
      for (final m in RegExp(r'#EXT-X-BYTERANGE:(\d+)@(\d+)\n(.+)').allMatches(playlist))
        (int.parse(m.group(1)!), int.parse(m.group(2)!), m.group(3)!.trim()),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  final worker = _Worker();
  // Two rungs: 90 fragments each (three minutes), small enough to be quick.
  final r720 = FakeCmaf.build(fragments: 90, fragmentBytes: 160 * 1024, seed: 1);
  final r360 = FakeCmaf.build(fragments: 90, fragmentBytes: 48 * 1024, seed: 2);

  setUpAll(() async {
    HttpOverrides.global = null;
    temp = await Directory.systemTemp.createTemp('hls');
    PathProviderPlatform.instance = _Paths(temp.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('mx_clone/media_scan'),
            (call) async => call.method == 'freeBytes' ? 64 * 1024 * 1024 * 1024 : null);
    worker.films['a720'] = r720.bytes;
    worker.films['a360'] = r360.bytes;
    await worker.start();
  });

  tearDownAll(() async {
    await worker.server.close(force: true);
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // a write finishing in the same instant
    }
  });

  Future<String> register(String id) async {
    final master = await StreamCacheServer.instance.hlsUrlFor(
      ladderId: id,
      startCacheId: '$id-720',
      aspect: 16 / 9,
      frameRate: 24,
      rungs: [
        HlsRungSource(
            height: 720, kbps: 655, cacheId: '$id-720', upstream: worker.url('a720'),
            refresh: () async => null, bytes: r720.bytes.length),
        HlsRungSource(
            height: 360, kbps: 196, cacheId: '$id-360', upstream: worker.url('a360'),
            refresh: () async => null, bytes: r360.bytes.length),
      ],
    );
    expect(master, isNotNull);
    return master!;
  }

  test('the master names both rungs; each media playlist is its file, byte for byte', () async {
    final master = await register('film1');
    final (code, body) = await _get(master);
    expect(code, 200);
    final text = String.fromCharCodes(body);
    final media = RegExp(r'^http://.+\.m3u8$', multiLine: true).allMatches(text).map((m) => m.group(0)!).toList();
    expect(media.length, 2);
    expect(media.first, endsWith('/720.m3u8'), reason: 'best first');
    expect(text, contains('RESOLUTION=1280x720'));

    for (final (url, film) in [(media[0], r720), (media[1], r360)]) {
      final (c2, pl) = await _get(url);
      expect(c2, 200);
      final segs = _segments(String.fromCharCodes(pl));
      expect(segs.length, 90);
      expect([for (final s in segs) s.$2], film.fragmentStarts);
      expect([for (final s in segs) s.$1], film.fragmentSizes);
    }
  });

  test('every segment comes back exactly, and the Worker is asked a few times, not 90',
      () async {
    final master = await register('film2');
    final (_, mbody) = await _get(master);
    final url720 = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(String.fromCharCodes(mbody))!.group(0)!;
    final (_, pl) = await _get(url720);
    final segs = _segments(String.fromCharCodes(pl));
    worker.asked.clear();
    for (final (size, at, url) in segs) {
      final (code, got) = await _get(url, range: 'bytes=$at-${at + size - 1}');
      expect(code, 206);
      expect(got, r720.bytes.sublist(at, at + size), reason: 'segment at $at');
    }
    final film = r720.bytes.length - r720.headEnd;
    final reads = worker.asked.where((a) => a.$1 == 'a720').length;
    // One read per segment would be 90; reading 2 MB ahead it is film / 2 MB.
    expect(reads, lessThanOrEqualTo((film / StreamCacheServer.segmentReadAhead).ceil() + 2),
        reason: '$reads reads for ${(film / 1048576).toStringAsFixed(1)} MB');
    // Nothing read twice.
    final read = worker.asked.where((a) => a.$1 == 'a720').fold<int>(0, (n, a) => n + a.$3 - a.$2 + 1);
    expect(read, lessThanOrEqualTo(r720.bytes.length));
  });

  test('a jump is answered at once, from where the player went', () async {
    final master = await register('film3');
    final (_, mbody) = await _get(master);
    final url = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(String.fromCharCodes(mbody))!.group(0)!;
    final segs = _segments(String.fromCharCodes((await _get(url)).$2));
    // Start, then jump two minutes on.
    final (s0, a0, u0) = segs[0];
    expect((await _get(u0, range: 'bytes=$a0-${a0 + s0 - 1}')).$2, r720.bytes.sublist(a0, a0 + s0));
    final (s60, a60, u60) = segs[60];
    final clock = Stopwatch()..start();
    final (code, got) = await _get(u60, range: 'bytes=$a60-${a60 + s60 - 1}');
    expect(code, 206);
    expect(got, r720.bytes.sublist(a60, a60 + s60));
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    // And on from there.
    final (s61, a61, u61) = segs[61];
    expect((await _get(u61, range: 'bytes=$a61-${a61 + s61 - 1}')).$2, r720.bytes.sublist(a61, a61 + s61));
  });

  test('a skip far ahead inside the read-ahead is a jump: answered at once, not after '
      'the bytes on the way to it', () async {
    final master = await register('film8');
    final (_, mbody) = await _get(master);
    final url = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(String.fromCharCodes(mbody))!.group(0)!;
    final segs = _segments(String.fromCharCodes((await _get(url)).$2));
    // About 1.7 Mbit/s: the 2 MB read ahead of a segment takes ten seconds.
    worker.paceMs = 300;
    addTearDown(() => worker.paceMs = 0);
    final (s10, a10, u10) = segs[10];
    expect((await _get(u10, range: 'bytes=$a10-${a10 + s10 - 1}')).$2,
        r720.bytes.sublist(a10, a10 + s10));
    // Twenty seconds on: inside that read ahead, 1.4 MB beyond where it is.
    final (s20, a20, u20) = segs[20];
    expect(a20 - a10, lessThan(StreamCacheServer.segmentReadAhead));
    final clock = Stopwatch()..start();
    final (code, got) = await _get(u20, range: 'bytes=$a20-${a20 + s20 - 1}');
    expect(code, 206);
    expect(got, r720.bytes.sublist(a20, a20 + s20));
    expect(clock.elapsed, lessThan(const Duration(seconds: 4)),
        reason: 'its own read, not the 1.4 MB in front of it');
  });

  test('a read-ahead that stalls is replaced after a quiet spell, not waited out',
      () async {
    final master = await register('film9');
    final (_, mbody) = await _get(master);
    final url = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(String.fromCharCodes(mbody))!.group(0)!;
    final segs = _segments(String.fromCharCodes((await _get(url)).$2));
    // The segment and a little of the next, then the connection goes dead.
    final (s30, a30, u30) = segs[30];
    worker.stallFrom = a30;
    worker.stallAfter = 192 * 1024;
    expect((await _get(u30, range: 'bytes=$a30-${a30 + s30 - 1}')).$2,
        r720.bytes.sublist(a30, a30 + s30));
    final (s31, a31, u31) = segs[31];
    final clock = Stopwatch()..start();
    final (code, got) = await _get(u31, range: 'bytes=$a31-${a31 + s31 - 1}');
    expect(code, 206);
    expect(got, r720.bytes.sublist(a31, a31 + s31));
    expect(clock.elapsed, lessThan(const Duration(seconds: 6)),
        reason: 'three quiet seconds, then a read of its own — it waited 20 s');
  });

  test("on a slow line the start rung's playlist is out as soon as its index is; "
      'the first segment goes on from where the head read stopped', () async {
    // About 1.7 Mbit/s: 300 ms for each 64 KB.
    worker.paceMs = 300;
    addTearDown(() => worker.paceMs = 0);
    final before = worker.asked.length;
    final clock = Stopwatch()..start();
    final master = await register('film10');
    final (_, mbody) = await _get(master);
    final url = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(String.fromCharCodes(mbody))!.group(0)!;
    final (code, pl) = await _get(url);
    expect(code, 200);
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 1800)),
        reason: 'the length check, then the index in the first 64 KB');
    final segs = _segments(String.fromCharCodes(pl));
    final (s0, a0, u0) = segs[0];
    expect(a0, lessThan(StreamCacheServer.headRead), reason: "the test film's head is small");
    expect((await _get(u0, range: 'bytes=$a0-${a0 + s0 - 1}')).$2,
        r720.bytes.sublist(a0, a0 + s0));
    // Beside the 8 KB that finds the film's length: the head once, then on
    // from its end.
    final film = worker.asked.skip(before)
        .where((a) => a.$1 == 'a720' && a.$3 - a.$2 + 1 > 8192).toList();
    expect(film.where((a) => a.$2 == 0).length, 1, reason: 'the head read once: $film');
    expect(film.where((a) => a.$2 > 0 && a.$2 < StreamCacheServer.headRead), isEmpty,
        reason: "the first segment's opening came from the head read: $film");
    expect(film.where((a) => a.$2 == StreamCacheServer.headRead), isNotEmpty);
  });

  test("a jump onto another rung ends the old rung's read ahead, which only held a "
      'connection and the line', () async {
    final master = await register('film11');
    final (_, mbody) = await _get(master);
    final text = String.fromCharCodes(mbody);
    final url720 = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(text)!.group(0)!;
    final url360 = RegExp(r'^http://.+/360\.m3u8$', multiLine: true).firstMatch(text)!.group(0)!;
    final s720 = _segments(String.fromCharCodes((await _get(url720)).$2));
    final s360 = _segments(String.fromCharCodes((await _get(url360)).$2));
    // About 1.7 Mbit/s: the 2 MB read ahead of a 720p segment takes ten
    // seconds.
    worker.paceMs = 300;
    addTearDown(() => worker.paceMs = 0);
    final (n10, a10, u10) = s720[10];
    expect((await _get(u10, range: 'bytes=$a10-${a10 + n10 - 1}')).$2,
        r720.bytes.sublist(a10, a10 + n10));
    // A change of quality and a jump in one: 360p, two minutes on.
    final (n60, a60, u60) = s360[60];
    expect((await _get(u60, range: 'bytes=$a60-${a60 + n60 - 1}')).$2,
        r360.bytes.sublist(a60, a60 + n60));
    // Long enough for 720p's read ahead, left running, to have brought
    // segment 15 (five segments at the line's pace).
    await Future<void>.delayed(const Duration(seconds: 5));
    final before = worker.asked.length;
    final (n15, a15, u15) = s720[15];
    expect((await _get(u15, range: 'bytes=$a15-${a15 + n15 - 1}')).$2,
        r720.bytes.sublist(a15, a15 + n15));
    expect(worker.asked.skip(before).where((x) => x.$1 == 'a720' && x.$2 == a15), isNotEmpty,
        reason: "720p's read ahead from segment 10 ended at the jump, so segment 15 is read now");
  });

  test('a segment answered 429 is waited out as asked, then comes back exactly',
      () async {
    final waits = <Duration>[];
    RateLimited.sleep = (d) async => waits.add(d);
    addTearDown(() => RateLimited.sleep = Future<void>.delayed);
    final master = await register('film5');
    final (_, mbody) = await _get(master);
    final url = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(String.fromCharCodes(mbody))!.group(0)!;
    final segs = _segments(String.fromCharCodes((await _get(url)).$2));
    worker.limited = 0;
    worker.limitNext = 1;
    final (s45, a45, u45) = segs[45];
    final (code, got) = await _get(u45, range: 'bytes=$a45-${a45 + s45 - 1}');
    expect(code, 206);
    expect(got, r720.bytes.sublist(a45, a45 + s45));
    expect(worker.limited, 1);
    expect(waits, [const Duration(seconds: 2)]);
  });

  test("registering the ladder checks the start rung's length and reads its head at "
      'once, on one connection, which then carries the first fragment', () async {
    worker.conns.clear();
    final master = await register('film7');
    // Before the player has asked for anything at all.
    bool film720((String, int, int, int) a) => a.$1 == 'a720' && a.$3 - a.$2 + 1 > 8192;
    for (var i = 0; i < 100 && !worker.conns.any(film720); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final head = worker.conns.where(film720).toList();
    expect(head.length, 1, reason: 'one read: ${worker.conns}');
    expect(head.single.$2, 0);
    expect(head.single.$3 + 1, StreamCacheServer.headRead,
        reason: 'the head only: the first fragment is the player\'s own request');
    final probe = worker.conns.where((a) => a.$1 == 'a720' && !film720(a)).toList();
    expect(probe.length, 1, reason: 'the 8 KB length check');
    expect(probe.single.$4, head.single.$4,
        reason: 'the length check\'s connection carried the head: one handshake, not two');
    final (_, mbody) = await _get(master);
    final url = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(String.fromCharCodes(mbody))!.group(0)!;
    final segs = _segments(String.fromCharCodes((await _get(url)).$2));
    final init = CmafHead.parse(r720.bytes)!;
    final (s0, a0, u0) = segs[0];
    // The init segment lives in the same file as the fragments.
    expect((await _get(u0, range: 'bytes=0-${init.initEnd - 1}')).$2,
        r720.bytes.sublist(0, init.initEnd));
    expect((await _get(u0, range: 'bytes=$a0-${a0 + s0 - 1}')).$2, r720.bytes.sublist(a0, a0 + s0));
    final a720 = worker.conns.where(film720).toList();
    expect(a720.where((a) => a.$2 < StreamCacheServer.headRead).toList(), head,
        reason: 'nothing in the head asked for twice: $a720');
    final on = a720.where((a) => a.$2 == StreamCacheServer.headRead).toList();
    expect(on, isNotEmpty, reason: 'the first fragment read on from the head: $a720');
    expect(on.first.$4, head.single.$4, reason: 'on the same connection');
  });

  test('played again, it comes from the phone', () async {
    final master = await register('film2');
    final (_, mbody) = await _get(master);
    final url = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(String.fromCharCodes(mbody))!.group(0)!;
    final segs = _segments(String.fromCharCodes((await _get(url)).$2));
    worker.asked.clear();
    for (final (size, at, u) in segs.take(20)) {
      expect((await _get(u, range: 'bytes=$at-${at + size - 1}')).$2, r720.bytes.sublist(at, at + size));
    }
    // Only the length check — the front 8 KB, read once per registration —
    // reaches the Worker; not one byte of the film.
    expect(worker.asked.where((a) => a.$1 == 'a720' && a.$3 - a.$2 + 1 > 8192), isEmpty,
        reason: 'only the length check reaches the Worker');
  });

  test("the rungs either side are read ahead: a change of rung waits for no index", () async {
    final master = await register('film5');
    final (_, mbody) = await _get(master);
    final text = String.fromCharCodes(mbody);
    final url720 = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(text)!.group(0)!;
    final url360 = RegExp(r'^http://.+/360\.m3u8$', multiLine: true).firstMatch(text)!.group(0)!;
    expect((await _get(url720)).$1, 200);
    // The 360p head arrives on its own, behind the 720p playlist.
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final last = worker.asked.lastOrNull;
      if (last != null && last.$1 == 'a360' && last.$3 >= 64 * 1024 - 1) break;
    }
    worker.asked.clear();
    final (code, pl) = await _get(url360);
    expect(code, 200);
    expect(_segments(String.fromCharCodes(pl)).length, 90);
    expect(worker.asked, isEmpty, reason: 'its index was already on the phone');
  });

  test("the seek bar's preview: the smallest rung's init and one fragment, read exactly",
      () async {
    final master = await register('film6');
    final (code6, m6) = await _get(master);
    expect(code6, 200);
    // The start rung's opening, read at registration, finished first: what
    // is counted below is the preview's alone.
    final url720 = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(String.fromCharCodes(m6))!.group(0)!;
    expect((await _get(url720)).$1, 200);
    final head360 = CmafHead.parse(r360.bytes)!;
    final idx360 = CmafIndex.parse(r360.bytes)!;
    // A moment in the 31st fragment.
    final at = Duration(milliseconds: idx360.timesMs[30] + 500);
    worker.asked.clear();
    final clip = await StreamCacheServer.instance.previewClip(at);
    expect(clip, isNotNull);
    expect(clip!.startMs, idx360.timesMs[30]);
    final want = BytesBuilder()
      ..add(r360.bytes.sublist(0, head360.initEnd))
      ..add(r360.bytes.sublist(idx360.starts[30], idx360.starts[30] + idx360.sizes[30]));
    expect(clip.film, want.toBytes(), reason: 'init + that fragment, byte for byte');
    // From the smallest rung, and no read-ahead: its head once (the index
    // and the init segment), then exactly the fragment.
    var reads = worker.asked.where((a) => a.$3 - a.$2 + 1 > 8192).toList();
    expect(reads.every((a) => a.$1 == 'a360'), isTrue, reason: '$reads');
    expect(reads.map((a) => a.$3 - a.$2 + 1), contains(idx360.sizes[30]));
    expect(reads.fold<int>(0, (n, a) => n + a.$3 - a.$2 + 1),
        lessThanOrEqualTo(64 * 1024 + idx360.sizes[30]));
    // The next picture: that fragment and nothing else.
    worker.asked.clear();
    final next = await StreamCacheServer.instance
        .previewClip(Duration(milliseconds: idx360.timesMs[60] + 100));
    expect(next?.startMs, idx360.timesMs[60]);
    reads = worker.asked.where((a) => a.$3 - a.$2 + 1 > 8192).toList();
    expect(reads.map((a) => a.$3 - a.$2 + 1).toList(), [idx360.sizes[60]]);
    // A picture already held: nothing read at all.
    worker.asked.clear();
    final again = await StreamCacheServer.instance.previewClip(at, have: (_) => true);
    expect(again?.film, isNull);
    expect(again?.startMs, idx360.timesMs[30]);
    expect(worker.asked, isEmpty);
  });

  test('a ladder released is gone', () async {
    final master = await register('film4');
    StreamCacheServer.instance.releaseLadder('film4');
    expect((await _get(master)).$1, 404);
  });
}
