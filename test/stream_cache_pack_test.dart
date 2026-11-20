import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_server.dart';
import 'package:innocent/features/video_hub/data/device_identity.dart';
import 'package:innocent/features/video_hub/data/stream_door.dart';
import 'package:innocent/features/video_hub/domain/trickplay_pack.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/cmaf.dart';
import 'support/itp1.dart';

/// The seek bar's pack read through the stream proxy like a rung
/// (StreamCacheServer.packRange, docs/trickplay_plan.md): the signed
/// address, the install's header — the Worker enforces bound tokens, and a
/// bound grant binds the pack's URL as it does the rungs', so a read
/// without the header is a 404 — the renewal, and NOTHING written to the
/// phone (no cache entry: pictures stay in memory).
class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// A Worker in miniature that ENFORCES BOUND TOKENS: a token plays only for
/// a request carrying [device] in X-Innocent-Device; otherwise 404, as the
/// real Worker answers (/health bind=enforce). [expired] tokens answer 410.
class _BoundWorker {
  final Map<String, Uint8List> films = <String, Uint8List>{};
  final Set<String> expired = <String>{};
  String device = 'install-test';
  late HttpServer server;
  final List<(String, int, int, String?)> asked = <(String, int, int, String?)>[];

  String url(String token) => 'http://127.0.0.1:${server.port}/v/$token';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      final token = req.uri.pathSegments.last;
      final who = req.headers.value(StreamDoor.header);
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(req.headers.value('range') ?? '');
      final a = m == null ? 0 : int.parse(m.group(1)!);
      final body = films[token];
      asked.add((token, a, m == null || m.group(2)!.isEmpty ? -1 : int.parse(m.group(2)!), who));
      if (expired.contains(token)) {
        res.statusCode = 410;
        await res.close();
        return;
      }
      if (body == null || who != device) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      var b = m == null || m.group(2)!.isEmpty ? body.length - 1 : int.parse(m.group(2)!);
      if (b >= body.length) b = body.length - 1;
      res.statusCode = m == null ? 200 : 206;
      if (m != null) res.headers.set('content-range', 'bytes $a-$b/${body.length}');
      res.contentLength = b - a + 1;
      res.add(body.sublist(a, b + 1));
      await res.close();
    });
  }
}

Future<Map<String, int>> _files(Directory d) async {
  final out = <String, int>{};
  if (!d.existsSync()) return out;
  await for (final f in d.list(recursive: true)) {
    if (f is File) out[f.path] = f.lengthSync();
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  final worker = _BoundWorker();
  final r720 = FakeCmaf.build(fragments: 30, fragmentBytes: 64 * 1024, seed: 11);
  final r360 = FakeCmaf.build(fragments: 30, fragmentBytes: 24 * 1024, seed: 12);
  // Made-up pictures (never a film's): 300 of them, a 40 KB-ish header run.
  final pictures = List<Uint8List>.generate(300, (i) => fakeJpeg(i, 2000 + (i * 53) % 1500));
  final pack = buildPack(pictures);
  final info = TrickplayInfo(
      url: 'unused', bytes: pack.length, intervalMs: 4000, width: 320, height: 180, count: 300);

  setUpAll(() async {
    HttpOverrides.global = null;
    temp = await Directory.systemTemp.createTemp('pack');
    PathProviderPlatform.instance = _Paths(temp.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('mx_clone/media_scan'),
            (call) async => call.method == 'freeBytes' ? 64 * 1024 * 1024 * 1024 : null);
    worker.films['r720'] = r720.bytes;
    worker.films['r360'] = r360.bytes;
    worker.films['pk1'] = pack;
    worker.films['pk2'] = pack;
    await worker.start();
    StreamDoor.allowPlainHttp = true;
    DeviceIdentity.debugCurrent = 'install-test';
    for (final t in ['r720', 'r360', 'pk1', 'pk2', 'pk-expired']) {
      StreamDoor.learn(worker.url(t));
    }
  });

  tearDownAll(() async {
    StreamDoor.allowPlainHttp = false;
    StreamDoor.reset();
    DeviceIdentity.debugCurrent = null;
    await worker.server.close(force: true);
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // a write finishing in the same instant
    }
  });

  Future<String> register(String id, {HlsPackSource? pack}) async {
    final master = await StreamCacheServer.instance.hlsUrlFor(
      ladderId: id,
      startCacheId: '$id-720',
      rungs: [
        HlsRungSource(
            height: 720, kbps: 655, cacheId: '$id-720', upstream: worker.url('r720'),
            refresh: () async => null, bytes: r720.bytes.length),
        HlsRungSource(
            height: 360, kbps: 196, cacheId: '$id-360', upstream: worker.url('r360'),
            refresh: () async => null, bytes: r360.bytes.length),
      ],
      pack: pack,
    );
    expect(master, isNotNull);
    return master!;
  }

  /// The pack's requests only (a rung's head read may still be going).
  List<(String, int, int, String?)> packAsks() =>
      worker.asked.where((a) => a.$1.startsWith('pk')).toList();

  /// Until the start rung's own head read (hlsUrlFor) is over.
  Future<void> quiet() async {
    var n = -1;
    while (n != worker.asked.length) {
      n = worker.asked.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  test('a bound grant\'s pack is read with the install\'s header, a range at a time', () async {
    final master = await register('packfilm1',
        pack: HlsPackSource(upstream: worker.url('pk1'), refresh: () async => null));
    expect(StreamCacheServer.instance.hasPack(master), isTrue);
    await quiet();
    worker.asked.clear();
    final head = await StreamCacheServer.instance.packRange(master, 0, 16384);
    expect(head, Uint8List.sublistView(pack, 0, 16384));
    final run = await StreamCacheServer.instance.packRange(master, 5000, 9000);
    expect(run, Uint8List.sublistView(pack, 5000, 9000));
    expect(packAsks().map((a) => (a.$1, a.$2, a.$3)).toList(),
        <(String, int, int)>[('pk1', 0, 16383), ('pk1', 5000, 8999)]);
    expect(packAsks().map((a) => a.$4).toSet(), <String?>{'install-test'},
        reason: 'every read of the pack names the install');
  });

  test('the reader on the proxy: header, one picture, a run of 31 — three requests', () async {
    final master = await register('packfilm2',
        pack: HlsPackSource(upstream: worker.url('pk1'), refresh: () async => null));
    await quiet();
    worker.asked.clear();
    final reqs = StreamCacheServer.instance.previewRequests;
    final reader = TrickplayPack(info, (a, b) => StreamCacheServer.instance.packRange(master, a, b));
    expect(await reader.pictureAt(const Duration(seconds: 579)), pictures[144]);
    expect(await reader.takeRun(130, 160), 31, reason: '144 inside the run is read again with it');
    expect(packAsks().length, 3);
    expect(StreamCacheServer.instance.previewRequests - reqs, 3);
  });

  test('without the install\'s header the Worker says 404: no bytes, never the wrong ones', () async {
    final master = await register('packfilm3',
        pack: HlsPackSource(upstream: worker.url('pk1'), refresh: () async => null));
    await quiet();
    DeviceIdentity.debugCurrent = null;
    try {
      expect(await StreamCacheServer.instance.packRange(master, 0, 16384), isNull);
    } finally {
      DeviceIdentity.debugCurrent = 'install-test';
    }
    expect(packAsks().last.$4, isNull);
    expect(packAsks().last.$1, 'pk1');
  });

  test('an expired link is renewed as a rung\'s, and read on the new one', () async {
    worker.expired.add('pk-expired');
    var renewed = 0;
    final master = await register('packfilm4',
        pack: HlsPackSource(
            upstream: worker.url('pk-expired'),
            refresh: () async {
              renewed++;
              return worker.url('pk2');
            }));
    await quiet();
    worker.asked.clear();
    final got = await StreamCacheServer.instance.packRange(master, 100, 2100);
    expect(got, Uint8List.sublistView(pack, 100, 2100));
    expect(renewed, 1);
    expect(packAsks().map((a) => a.$1).toList(), <String>['pk-expired', 'pk2']);
    // The renewed address is kept.
    worker.asked.clear();
    await StreamCacheServer.instance.packRange(master, 0, 24);
    expect(packAsks().single.$1, 'pk2');
  });

  test('NOTHING OF THE PACK IS WRITTEN TO THE PHONE: no cache entry, no file', () async {
    final master = await register('packfilm5',
        pack: HlsPackSource(upstream: worker.url('pk1'), refresh: () async => null));
    await quiet();
    final before = await _files(temp);
    final reader = TrickplayPack(info, (a, b) => StreamCacheServer.instance.packRange(master, a, b));
    for (var i = 0; i < 300; i += 25) {
      await reader.takeRun(i, i + 24);
    }
    expect(reader.heldCount, greaterThan(250));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final after = await _files(temp);
    expect(after, before, reason: 'the pack has no cache entry: no file made or grown');
  });

  test('a ladder without a pack has none; an unknown ladder address reads nothing', () async {
    final master = await register('packfilm6');
    expect(StreamCacheServer.instance.hasPack(master), isFalse);
    expect(await StreamCacheServer.instance.packRange(master, 0, 100), isNull);
    expect(
        await StreamCacheServer.instance
            .packRange('http://127.0.0.1:1/h/nottoken/packfilm1/master.m3u8', 0, 100),
        isNull);
  });
}
