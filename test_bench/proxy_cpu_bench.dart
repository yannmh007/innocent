// CPU per megabyte of the HLS segment path, and how many times the sealed
// cache asks the cipher — the cost that lands on the thread that draws the
// app on a phone (Flutter 3.29+ runs Dart on Android's main thread).
//
// A Range server in the same process hands the film over in 16 KB pieces, a
// TLS record each, as a phone's socket does; the proxy plays every segment
// of a 720p rung the way ExoPlayer asks for them. CPU is the process's own
// (/proc/self/stat), server and client included: compare runs, not the
// absolute figure.
//
//   BENCH_SEALED=1 BENCH_ROUNDS=4 flutter test test_bench/proxy_cpu_bench.dart
//
// 2026-10-29, sealed, 58.6 MB: before gathering, 3,800-4,100 seals and
// 114-126 ms/MB; gathered (64 KB while the player waits, 128 KB ahead of it),
// 1,520-1,620 seals and 102-106 ms/MB.
//
// A bench, run like a test: the test-only hooks are the point of it.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_server.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/cmaf.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

int _cpuTicks() {
  final f = File('/proc/self/stat').readAsStringSync();
  final parts = f.substring(f.lastIndexOf(')') + 2).split(' ');
  return int.parse(parts[11]) + int.parse(parts[12]); // utime + stime
}

Future<int> _get(HttpClient c, String url, {String? range}) async {
  final req = await c.getUrl(Uri.parse(url));
  if (range != null) req.headers.set('range', range);
  final resp = await req.close();
  var n = 0;
  await for (final chunk in resp) {
    n += chunk.length;
  }
  return n;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cpu per MB, HLS segments', () async {
    HttpOverrides.global = null;
    final sealed = Platform.environment['BENCH_SEALED'] == '1';
    final temp = await Directory.systemTemp.createTemp('cpubench');
    PathProviderPlatform.instance = _Paths(temp.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('mx_clone/media_scan'),
        (call) async => call.method == 'freeBytes' ? 64 * 1024 * 1024 * 1024 : null);
    var calls = 0;
    if (sealed) {
      final rnd = Random(5);
      m.setMockMethodCallHandler(const MethodChannel('mx_clone/media_crypto'), (call) async {
        switch (call.method) {
          case 'selfTest':
            return true;
          case 'newIv':
            return base64Encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
          case 'transform':
            calls++;
            final a = call.arguments as Map<Object?, Object?>;
            return Uint8List.fromList(a['bytes']! as Uint8List);
        }
        return null;
      });
    }
    final film = FakeCmaf.build(fragments: 150, fragmentBytes: 400 * 1024, seed: 3);
    final small = FakeCmaf.build(fragments: 150, fragmentBytes: 60 * 1024, seed: 4);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      final body = req.uri.pathSegments.last == 'a720' ? film.bytes : small.bytes;
      final mm = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(req.headers.value('range') ?? '');
      final a = mm == null ? 0 : int.parse(mm.group(1)!);
      var b = mm == null || mm.group(2)!.isEmpty ? body.length - 1 : int.parse(mm.group(2)!);
      if (b >= body.length) b = body.length - 1;
      res.statusCode = mm == null ? 200 : 206;
      if (mm != null) res.headers.set('content-range', 'bytes $a-$b/${body.length}');
      res.contentLength = b - a + 1;
      try {
        // In TLS-record-sized pieces, as a phone's socket hands them over.
        for (var at = a; at <= b; at += 16 * 1024) {
          res.add(Uint8List.sublistView(body, at, min(at + 16 * 1024, b + 1)));
          await res.flush();
          await Future<void>.delayed(const Duration(microseconds: 300));
        }
        await res.close();
      } catch (_) {}
    });
    final base = 'http://127.0.0.1:${server.port}/v';
    final c = HttpClient();
    final rounds = int.tryParse(Platform.environment["BENCH_ROUNDS"] ?? "") ?? 3;
    for (var round = 0; round < rounds; round++) {
      final id = 'bench$round';
      final master = await StreamCacheServer.instance.hlsUrlFor(
        ladderId: id,
        startCacheId: '$id-720',
        aspect: 16 / 9,
        frameRate: 24,
        rungs: [
          HlsRungSource(height: 720, kbps: 1600, cacheId: '$id-720', upstream: '$base/a720',
              refresh: () async => null, bytes: film.bytes.length),
          HlsRungSource(height: 360, kbps: 240, cacheId: '$id-360', upstream: '$base/a360',
              refresh: () async => null, bytes: small.bytes.length),
        ],
      );
      final mtext = utf8.decode(await (await (await c.getUrl(Uri.parse(master!))).close()).fold<List<int>>([], (p, e) => p..addAll(e)));
      final url = RegExp(r'^http://.+/720\.m3u8$', multiLine: true).firstMatch(mtext)!.group(0)!;
      final pl = utf8.decode(await (await (await c.getUrl(Uri.parse(url))).close()).fold<List<int>>([], (p, e) => p..addAll(e)));
      final segs = [
        for (final s in RegExp(r'#EXT-X-BYTERANGE:(\d+)@(\d+)\n(.+)').allMatches(pl))
          (int.parse(s.group(1)!), int.parse(s.group(2)!), s.group(3)!.trim()),
      ];
      calls = 0;
      final t0 = _cpuTicks();
      final sw = Stopwatch()..start();
      var bytes = 0;
      for (final (n, at, u) in segs) {
        bytes += await _get(c, u, range: 'bytes=$at-${at + n - 1}');
      }
      final ticks = _cpuTicks() - t0;
      final mb = bytes / 1048576;
      // ignore: avoid_print
      print('BENCH sealed=$sealed round=$round ${mb.toStringAsFixed(1)} MB in ${sw.elapsedMilliseconds} ms, '
          'cpu ${ticks * 10} ms = ${(ticks * 10 / mb).toStringAsFixed(1)} ms/MB, seals $calls');
    }
    c.close(force: true);
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
