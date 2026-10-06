import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_server.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// A stream Worker in miniature: answers ranges with 206, refuses a link
/// that has "expired", and counts what it was asked and on how many
/// connections.
class _Upstream {
  _Upstream(this.body);
  final Uint8List body;
  late HttpServer server;
  final Set<String> valid = <String>{'t1'};
  final Set<int> ports = <int>{};
  int requests = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  int refused = 0;
  final Map<int, String> open = <int, String>{};
  int _seq = 0;

  String url(String token) => 'http://127.0.0.1:${server.port}/v/$token';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final token = req.uri.pathSegments.last;
    if (!valid.contains(token)) {
      refused++;
      res.statusCode = 403;
      await res.close();
      return;
    }
    requests++;
    ports.add(req.connectionInfo!.remotePort);
    inFlight++;
    maxInFlight = max(maxInFlight, inFlight);
    var counted = true;
    final me = _seq++;
    open[me] = '${req.headers.value(HttpHeaders.rangeHeader)}';
    try {
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
      // Paced a little, so lanes genuinely overlap rather than finishing in
      // the instant each is opened.
      for (var at = start; at <= end; at += 256 * 1024) {
        res.add(Uint8List.sublistView(body, at, min(at + 256 * 1024, end + 1)));
        await res.flush();
        if (at + 256 * 1024 <= end) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }
      // Counted as done once the last byte is written, not once the close
      // handshake finishes — that lag is not a second request in flight.
      inFlight--;
      counted = false;
      open.remove(me);
      await res.close();
    } catch (_) {
      // The proxy closed early (a seek): fine.
    } finally {
      if (counted) inFlight--;
      open.remove(me);
    }
  }
}

Future<Uint8List> _get(String url, {int? from, int? take}) async {
  final c = HttpClient();
  try {
    final r = await c.getUrl(Uri.parse(url));
    if (from != null) r.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
    final resp = await r.close();
    final out = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      out.add(chunk);
      if (take != null && out.length >= take) break;
    }
    final all = out.takeBytes();
    return take != null && all.length > take ? Uint8List.sublistView(all, 0, take) : all;
  } finally {
    c.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late _Upstream up;
  const mb = 1024 * 1024;

  setUpAll(() async {
    HttpOverrides.global = null;
    temp = await Directory.systemTemp.createTemp('streamcache');
    PathProviderPlatform.instance = _FakePaths(temp.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Plenty of room, so the cache keeps what passes through.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('mx_clone/media_scan'),
            (call) async => call.method == 'freeBytes' ? 64 * 1024 * 1024 * 1024 : null);
    final r = Random(11);
    up = _Upstream(Uint8List.fromList(List<int>.generate(40 * mb + 12345, (_) => r.nextInt(256))));
    await up.start();
  });

  tearDownAll(() async {
    await up.server.close(force: true);
    await temp.delete(recursive: true);
  });

  setUp(() async {
    // The last test's server handlers finish writing into closed sockets
    // before the counts here mean anything.
    for (var i = 0; i < 100 && up.inFlight > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    up.requests = 0;
    up.maxInFlight = 0;
    up.refused = 0;
    up.ports.clear();
    up.valid
      ..clear()
      ..add('t1');
    StreamCacheServer.lanes = 3;
  });

  test('a whole film arrives byte for byte, on three connections at once, reused',
      () async {
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-a', upstream: up.url('t1'), refresh: () async => null);
    expect(local, isNotNull);
    final got = await _get(local!);
    expect(got.length, up.body.length);
    expect(got, up.body);
    expect(up.maxInFlight, greaterThanOrEqualTo(3),
        reason: 'the stretch must be fetched in parallel lanes');
    expect(up.ports.length, lessThan(up.requests),
        reason: 'connections are kept and reused, not opened per request '
            '(${up.ports.length} connections for ${up.requests} requests)');
    StreamCacheServer.instance.release('film-a');
  });

  test('a seek into the middle gets exactly those bytes', () async {
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-b', upstream: up.url('t1'), refresh: () async => null);
    const from = 17 * mb + 4321;
    final got = await _get(local!, from: from, take: 12 * mb);
    expect(got, Uint8List.sublistView(up.body, from, from + 12 * mb));
    // The player went away part way through a stretch: nothing it started
    // may stay open on the server (a leaked lane holds a pooled connection
    // mid-response, and enough seeks would starve the pool).
    for (var i = 0; i < 100 && up.inFlight > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (up.inFlight > 0) {
      // ignore: avoid_print
      print('still open after the seek: ${up.open}');
    }
    expect(up.inFlight, 0, reason: 'connections left open after a seek');
    StreamCacheServer.instance.release('film-b');
  });

  test('a link that expires mid-film is renewed and the film carries on', () async {
    var renewals = 0;
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-c',
        upstream: up.url('t1'),
        refresh: () async {
          renewals++;
          up.valid.add('t2');
          return up.url('t2');
        });
    // Expire the first link once some of the film has gone out.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 60), () => up.valid.remove('t1')));
    final got = await _get(local!);
    expect(got, up.body);
    expect(renewals, greaterThanOrEqualTo(1));
    StreamCacheServer.instance.release('film-c');
  });

  test('played again, it comes from the phone and not the network', () async {
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-a', upstream: up.url('t1'), refresh: () async => null);
    up.requests = 0;
    final got = await _get(local!);
    expect(got, up.body);
    expect(up.requests, lessThanOrEqualTo(1), reason: 'only the length check');
    StreamCacheServer.instance.release('film-a');
  });

  test('lanes = 1 is the old single connection, still byte-exact', () async {
    StreamCacheServer.lanes = 1;
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-d', upstream: up.url('t1'), refresh: () async => null);
    final got = await _get(local!);
    expect(got, up.body);
    // One request at a time. Server and proxy share an event loop here, so
    // the next request can arrive before the last handler has noticed its
    // final write went out: two, never the three the lanes reach.
    expect(up.maxInFlight, lessThanOrEqualTo(2));
    StreamCacheServer.instance.release('film-d');
  });
}
