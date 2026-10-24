import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_server.dart';
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

  String url(String name) => 'http://127.0.0.1:${server.port}/v/$name';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
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
      res.statusCode = m == null ? 200 : 206;
      if (m != null) res.headers.set('content-range', 'bytes $a-$b/${body.length}');
      res.contentLength = b - a + 1;
      try {
        // A little at a time, as a line delivers it.
        for (var at = a; at <= b; at += 64 * 1024) {
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

  test('a ladder released is gone', () async {
    final master = await register('film4');
    StreamCacheServer.instance.releaseLadder('film4');
    expect((await _get(master)).$1, 404);
  });
}
