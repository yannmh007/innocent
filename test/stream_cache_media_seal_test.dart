// The stream proxy playing a sealed film (docs/MEDIA_ENCRYPTION.md §6): the
// proxy routes a sealed grant's URL through the unseal gateway and does
// everything else exactly as for a plain film — lanes, seeks, its cache, an
// expired link renewed — and the player only ever sees the film's own bytes.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_server.dart';
import 'package:innocent/features/video_hub/data/seal/media_seal.dart';
import 'package:innocent/features/video_hub/data/seal/unseal_gateway.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_sealed_worker.dart';
import 'support/seal_test_cipher.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Future<Uint8List> _get(String url, {int? from, int? to}) async {
  final c = HttpClient();
  try {
    final r = await c.getUrl(Uri.parse(url));
    if (from != null) r.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-${to ?? ''}');
    final resp = await r.close();
    final out = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      out.add(chunk);
    }
    return out.takeBytes();
  } finally {
    c.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late FakeWorker worker;
  late Uint8List plain;
  late SealGrant seal;
  late String upstream;
  late TestSealCipher cipher;
  final rnd = Random(21);
  Uint8List bytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));

  setUpAll(() async {
    HttpOverrides.global = null;
    temp = await Directory.systemTemp.createTemp('sealedcache');
    PathProviderPlatform.instance = _FakePaths(temp.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('mx_clone/media_scan'),
            (call) async => call.method == 'freeBytes' ? 64 * 1024 * 1024 * 1024 : null);
    plain = bytes(1536 * 1024 + 777);
    final dek = bytes(32);
    final sealed = sealObject(dek, 'dek-proxy', plain, salt: bytes(32), prefix: bytes(7));
    worker = FakeWorker(sealed);
    upstream = await worker.start();
    seal = SealGrant(
      dekId: 'dek-proxy',
      plainSize: plain.length,
      sealedSize: sealed.length,
      wrap: 'tls',
      dek: base64Encode(dek),
      header: Uint8List.sublistView(sealed, 0, 40),
    );
    cipher = TestSealCipher();
    UnsealGateway.instance = UnsealGateway(cipher: cipher);
    StreamCacheServer.lanes = 3;
  });

  tearDownAll(() async {
    await UnsealGateway.instance.shutdown();
    await worker.stop();
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // A write finishing in the same instant.
    }
  });

  setUp(() {
    SealedUrls.reset();
  });

  test('a sealed film through the proxy is the film, byte for byte; seeks too', () async {
    SealedUrls.learn(upstream, seal);
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'sealed-a', upstream: upstream, refresh: () async => null, total: plain.length);
    expect(local, isNotNull);
    expect(await _get(local!), plain);
    for (final (a, b) in <(int, int)>[(0, 99), (65479, 65481), (700000, 900000), (plain.length - 5, plain.length - 1)]) {
      expect(await _get(local, from: a, to: b), plain.sublist(a, b + 1), reason: '$a-$b');
    }
    expect(cipher.segments, greaterThan(0), reason: 'the gateway opened it');
    // The proxy's own cache holds the film now: read again, nothing goes out.
    final before = worker.requests;
    expect(await _get(local, from: 300000, to: 400000), plain.sublist(300000, 400001));
    expect(worker.requests, before, reason: 'served from the phone');
    StreamCacheServer.instance.release('sealed-a');
  });

  test('an expired sealed link is renewed through the gateway, mid-film', () async {
    SealedUrls.learn(upstream, seal);
    final renewed = '$upstream?renewed';
    var refreshes = 0;
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'sealed-b',
        upstream: upstream,
        total: plain.length,
        refresh: () async {
          refreshes++;
          SealedUrls.learn(renewed, seal);
          return renewed;
        });
    worker.refuse
      ..add((403, null))
      ..add((403, null));
    final got = await _get(local!, from: 1000000);
    expect(got, plain.sublist(1000000));
    expect(refreshes, greaterThanOrEqualTo(1));
    StreamCacheServer.instance.release('sealed-b');
  });

  test('renewed as the plain twin: the same film, read as it is', () async {
    SealedUrls.learn(upstream, seal);
    final twin = FakeWorker(plain);
    final plainUrl = await twin.start();
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'sealed-c',
        upstream: upstream,
        total: plain.length,
        refresh: () async => plainUrl);
    worker.refuse
      ..add((403, null))
      ..add((403, null));
    expect(await _get(local!, from: 500000, to: 600000), plain.sublist(500000, 600001));
    expect(twin.requests, greaterThan(0), reason: 'read from the plain twin');
    StreamCacheServer.instance.release('sealed-c');
    await twin.stop();
  });

  test('a plain film renewed sealed is routed through the gateway, never read as noise', () async {
    final twin = FakeWorker(plain);
    final plainUrl = await twin.start();
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'sealed-d',
        upstream: plainUrl,
        total: plain.length,
        refresh: () async {
          SealedUrls.learn(upstream, seal);
          return upstream;
        });
    twin.refuse
      ..add((403, null))
      ..add((403, null))
      ..add((403, null));
    final before = cipher.segments;
    expect(await _get(local!, from: 1200000, to: 1300000), plain.sublist(1200000, 1300001));
    expect(cipher.segments, greaterThan(before), reason: 'opened, not passed through');
    StreamCacheServer.instance.release('sealed-d');
    await twin.stop();
  });
}
