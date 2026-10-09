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
  /// Bytes written to the proxy, all requests together.
  int sent = 0;
  final Map<int, String> open = <int, String>{};
  /// The size of every range asked for, in the order the requests arrived.
  final List<int> sizes = <int>[];
  /// The pause between two [piece]-sized writes of one response: a slow line.
  Duration pace = const Duration(milliseconds: 2);
  int piece = 256 * 1024;
  /// The local port of the connection each request came in on, in order.
  final List<int> requestPorts = <int>[];
  /// Every range asked for, `(first, last)` inclusive, in arrival order.
  final List<(int, int)> ranges = <(int, int)>[];
  /// Answers every request with the whole film, as a server that does not
  /// do ranges would.
  bool ignoreRange = false;
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
    requestPorts.add(req.connectionInfo!.remotePort);
    inFlight++;
    maxInFlight = max(maxInFlight, inFlight);
    var counted = true;
    final me = _seq++;
    open[me] = '${req.headers.value(HttpHeaders.rangeHeader)}';
    try {
      var start = 0, end = body.length - 1;
      final h = req.headers.value(HttpHeaders.rangeHeader);
      if (h != null && !ignoreRange) {
        final spec = h.substring(6).split('-');
        start = int.parse(spec[0]);
        if (spec[1].isNotEmpty) end = min(int.parse(spec[1]), body.length - 1);
        res.statusCode = 206;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${body.length}');
      }
      sizes.add(end - start + 1);
      ranges.add((start, end));
      res.headers.contentLength = end - start + 1;
      // Paced a little, so lanes genuinely overlap rather than finishing in
      // the instant each is opened.
      for (var at = start; at <= end; at += piece) {
        res.add(Uint8List.sublistView(body, at, min(at + piece, end + 1)));
        // A flush that does not finish is a client that has gone: dart:io
        // waits on a destroyed connection forever, and "still open" would
        // then measure this server, not the proxy. The proxy reads every
        // part as fast as it arrives, so two seconds is never a slow reader.
        await res.flush().timeout(const Duration(seconds: 2));
        sent += min(piece, end + 1 - at);
        if (at + piece <= end) {
          await Future<void>.delayed(pace);
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
    up.sizes.clear();
    up.pace = const Duration(milliseconds: 2);
    up.piece = 256 * 1024;
    up.requestPorts.clear();
    up.ranges.clear();
    up.ignoreRange = false;
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

  test('a stretch starts on small parts and grows to full size', () async {
    const k = 1024;
    expect(StreamCacheServer.rampedPartBytes(0), 128 * k);
    expect(StreamCacheServer.rampedPartBytes(1), 256 * k);
    expect(StreamCacheServer.rampedPartBytes(5), 768 * k);
    expect(StreamCacheServer.rampedPartBytes(15), 2 * mb);
    expect(StreamCacheServer.rampedPartBytes(500), 2 * mb);

    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-ramp', upstream: up.url('t1'), refresh: () async => null);
    final got = await _get(local!);
    expect(got, up.body);
    // The two-byte length check aside, the stretch opens on its three
    // smallest parts — what stands between Play and the picture — and every
    // part after is no smaller than the one before, up to full size.
    // (The 8 KB is the length check, which also reads where the index is.)
    final parts = up.sizes.where((s) => s != 8 * 1024).toList();
    expect(parts.take(3).toSet(), {128 * k, 256 * k, 384 * k},
        reason: 'first requests: $parts');
    expect(parts.where((s) => s < 2 * mb).length, greaterThanOrEqualTo(15),
        reason: '$parts');
    expect(parts, contains(2 * mb));
    StreamCacheServer.instance.release('film-ramp');
  });

  test('the index is found in the first bytes, wherever it is', () {
    Uint8List box(String kind, int size, [int fill = 0]) {
      final b = Uint8List(size < 16 ? 16 : 16);
      final v = ByteData.sublistView(b);
      v.setUint32(0, size);
      b.setRange(4, 8, kind.codeUnits);
      return b.sublist(0, 8);
    }
    Uint8List cat(List<Uint8List> parts, [int pad = 0]) =>
        Uint8List.fromList([for (final p in parts) ...p, ...List<int>.filled(pad, 0)]);
    // faststart: ftyp(32) moov(4 MB) mdat(...)
    final ftyp = Uint8List.fromList([...box('ftyp', 32), ...List<int>.filled(24, 0)]);
    final fast = cat([ftyp, box('moov', 4 * mb)], 1000);
    expect(StreamCacheServer.indexRange(fast, 900 * mb), (32, 32 + 4 * mb));
    // written straight out: ftyp(32) free(8) mdat(800 MB) moov(...) to the end
    final last = cat([ftyp, box('free', 8), box('mdat', 800 * mb)], 1000);
    expect(StreamCacheServer.indexRange(last, 806 * mb), (40 + 800 * mb, 806 * mb));
    // a 64-bit mdat size
    final big = BytesBuilder()
      ..add(ftyp)
      ..add([0, 0, 0, 1, ...'mdat'.codeUnits]);
    final ext = ByteData(8)..setUint64(0, 5000 * mb);
    big.add(ext.buffer.asUint8List());
    expect(StreamCacheServer.indexRange(big.takeBytes(), 5006 * mb), (32 + 5000 * mb, 5006 * mb));
    // not an MP4 at all
    expect(StreamCacheServer.indexRange(Uint8List.fromList(List<int>.generate(4096, (i) => i % 7)), 10 * mb), isNull);
  });

  test('a film whose index is at the front gets the index on every lane at once', () async {
    // An MP4 head on the test body: ftyp, then a 3 MB moov.
    final saved = Uint8List.fromList(up.body.sublist(0, 40));
    final v = ByteData.sublistView(up.body);
    v.setUint32(0, 32);
    up.body.setRange(4, 8, 'ftyp'.codeUnits);
    v.setUint32(32, 3 * mb);
    up.body.setRange(36, 40, 'moov'.codeUnits);
    try {
      final local = await StreamCacheServer.instance.localUrlFor(
          cacheId: 'film-index', upstream: up.url('t1'), refresh: () async => null);
      final got = await _get(local!, take: 6 * mb);
      expect(got, Uint8List.sublistView(up.body, 0, 6 * mb));
      final parts = up.sizes.where((s) => s != 8 * 1024).toList();
      // 3 MB of index + 32 bytes + 1 MB of film, over three lanes: three
      // equal parts of about 1.4 MB in the first round, not 128/256/384 KB.
      final first = parts.take(3).toList();
      expect(first.fold<int>(0, (a, b) => a + b), 3 * mb + 32 + mb,
          reason: 'first requests: $parts');
      expect(first.every((s) => s >= mb), isTrue, reason: 'first requests: $parts');
    } finally {
      up.body.setRange(0, 40, saved);
      StreamCacheServer.instance.release('film-index');
    }
  });

  test('on a slow line the index reaches the player as it arrives, not once a part is whole',
      () async {
    // The bug this guards (device lab run 37776589997): the index of a long
    // film went out in equal parts, each handed on once whole. On a 4 Mbit
    // line the first part took twenty seconds; mpv hangs up on a connection
    // silent for ten, asked again, and the film never opened.
    final saved = Uint8List.fromList(up.body.sublist(0, 40));
    final v = ByteData.sublistView(up.body);
    v.setUint32(0, 32);
    up.body.setRange(4, 8, 'ftyp'.codeUnits);
    v.setUint32(32, 3 * mb);
    up.body.setRange(36, 40, 'moov'.codeUnits);
    // About 1.4 MB a part on three lanes: six pieces, a second and a half.
    up.pace = const Duration(milliseconds: 300);
    final c = HttpClient();
    try {
      final local = await StreamCacheServer.instance.localUrlFor(
          cacheId: 'film-trickle', upstream: up.url('t1'), refresh: () async => null);
      final clock = Stopwatch()..start();
      final resp = await (await c.getUrl(Uri.parse(local!))).close();
      final out = BytesBuilder(copy: false);
      int? firstAt;
      await for (final chunk in resp) {
        out.add(chunk);
        if (firstAt == null && out.length >= 256 * 1024) firstAt = clock.elapsedMilliseconds;
        if (out.length >= 4 * mb) break;
      }
      final whole = clock.elapsedMilliseconds;
      final got = out.takeBytes();
      expect(Uint8List.sublistView(got, 0, 4 * mb), Uint8List.sublistView(up.body, 0, 4 * mb));
      expect(firstAt, lessThan(900),
          reason: 'the first 256 KB took $firstAt ms (4 MB in $whole ms): '
              'held back until the whole first part was in');
    } finally {
      c.close(force: true);
      up.body.setRange(0, 40, saved);
      StreamCacheServer.instance.release('film-trickle');
    }
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

  test('a player that hangs up stops the download', () async {
    // The bug this guards: dart:io's HttpResponse never tells a server its
    // client has gone, so after a seek the proxy went on fetching the rest of
    // the stretch — 32 MB — and then the rest of the film, for nobody.
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-gone', upstream: up.url('t1'), refresh: () async => null);
    up.sent = 0;
    final got = await _get(local!, take: 2 * mb);
    expect(got, Uint8List.sublistView(up.body, 0, 2 * mb));
    await Future<void>.delayed(const Duration(seconds: 1));
    final after = up.sent;
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(up.sent, after, reason: 'still downloading a second after the hang-up');
    expect(up.sent, lessThan(12 * mb),
        reason: '${(up.sent / mb).toStringAsFixed(1)} MB fetched for a player that took 2 MB');
    StreamCacheServer.instance.release('film-gone');
  });

  test('a server that ignores the range is not read to the end', () async {
    // A 200 with the whole film where a 206 was asked for: the length check
    // used to drain it, and a refused lane's cancel read it out for the pool
    // — the film's full size each, for nothing.
    up.ignoreRange = true;
    up.sent = 0;
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-norange', upstream: up.url('t1'), refresh: () async => null);
    try {
      await _get(local!, take: mb).timeout(const Duration(seconds: 10));
    } catch (_) {
      // Whatever the player sees, the point is what was fetched.
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(up.sent, lessThan(12 * mb),
        reason: '${(up.sent / mb).toStringAsFixed(1)} MB read of a server that sent the whole film');
    up.ignoreRange = false;
    StreamCacheServer.instance.release('film-norange');
  });

  test('a server that ignores the range never has its first bytes passed off as the middle',
      () async {
    // One connection (the path a short gap between two held runs takes):
    // a 200 used to be taken as the bytes asked for, wherever they were.
    StreamCacheServer.lanes = 1;
    up.ignoreRange = true;
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-norange-mid', upstream: up.url('t1'), refresh: () async => null);
    const from = 5 * mb + 17;
    Uint8List got;
    try {
      got = await _get(local!, from: from, take: 2 * mb).timeout(const Duration(seconds: 10));
    } catch (_) {
      got = Uint8List(0);
    }
    expect(got, Uint8List.sublistView(up.body, from, from + got.length),
        reason: 'bytes from the start of the film served as bytes from $from');
    up.ignoreRange = false;
    StreamCacheServer.instance.release('film-norange-mid');
  });

  test('a range with an end gets exactly that many bytes', () async {
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-bounded', upstream: up.url('t1'), refresh: () async => null);
    final c = HttpClient();
    try {
      for (final (a, b) in [(1000, 5000), (7 * mb + 3, 9 * mb), (0, 3 * mb)]) {
        final r = await c.getUrl(Uri.parse(local!));
        r.headers.set(HttpHeaders.rangeHeader, 'bytes=$a-$b');
        final resp = await r.close();
        expect(resp.statusCode, 206);
        final out = BytesBuilder(copy: false);
        await for (final chunk in resp) {
          out.add(chunk);
        }
        expect(out.takeBytes(), Uint8List.sublistView(up.body, a, b + 1), reason: 'bytes=$a-$b');
      }
    } finally {
      c.close(force: true);
      StreamCacheServer.instance.release('film-bounded');
    }
  });

  test('a read abandoned at once costs one connection, not one per lane', () async {
    // A seek into a fragmented film reads a fragment header and jumps. Six
    // lanes opened at once were six connections torn down per jump, each a
    // new handshake for the next request; the other lanes now wait for the
    // first part to show the player is reading on.
    StreamCacheServer.lanes = 6;
    up.piece = 16 * 1024;
    up.pace = const Duration(milliseconds: 80); // 128 KB takes ~0.6 s
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-jump', upstream: up.url('t1'), refresh: () async => null);
    await Future<void>.delayed(const Duration(milliseconds: 300)); // the length check
    up.sizes.clear();
    final c = HttpClient();
    try {
      final r = await c.getUrl(Uri.parse(local!));
      r.headers.set(HttpHeaders.rangeHeader, 'bytes=${17 * mb}-');
      final resp = await r.close();
      var got = 0;
      await for (final chunk in resp) {
        got += chunk.length;
        if (got >= 16 * 1024) break; // the header read; the player jumps
      }
    } finally {
      c.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(up.sizes.length, 1,
        reason: 'ranges asked for a read abandoned after 16 KB: ${up.sizes}');
    StreamCacheServer.instance.release('film-jump');
  });

  test('a part nearly through when the player hangs up is let finish, and its '
      'connection carries the next request', () async {
    StreamCacheServer.lanes = 2;
    up.piece = 32 * 1024;
    up.pace = const Duration(milliseconds: 60);
    final local = await StreamCacheServer.instance.localUrlFor(
        cacheId: 'film-warm', upstream: up.url('t1'), refresh: () async => null);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    up.requestPorts.clear();
    // Read 64 KB of the first 128 KB part, then hang up: 64 KB to come.
    final c = HttpClient();
    try {
      final r = await c.getUrl(Uri.parse(local!));
      r.headers.set(HttpHeaders.rangeHeader, 'bytes=${21 * mb}-');
      final resp = await r.close();
      var got = 0;
      await for (final chunk in resp) {
        got += chunk.length;
        if (got >= 64 * 1024) break;
      }
    } finally {
      c.close(force: true);
    }
    final first = up.requestPorts.first;
    await Future<void>.delayed(const Duration(milliseconds: 800)); // it finishes
    await _get(local, from: 30 * mb, take: 64 * 1024).timeout(const Duration(seconds: 10));
    final later = up.requestPorts.skip(1).toList();
    expect(later, contains(first),
        reason: 'the finished part\'s connection ($first) was not reused: $later');
    StreamCacheServer.instance.release('film-warm');
  });

  test('after a seek the parts come in rounds of equal size, growing to full size', () {
    const k = 1024;
    StreamCacheServer.lanes = 6;
    // A round is one part per lane, all the same size, so they finish
    // together at the speed of the whole line.
    for (var i = 0; i < 6; i++) {
      expect(StreamCacheServer.seekPartBytes(i), 64 * k, reason: 'part $i');
    }
    expect(StreamCacheServer.seekPartBytes(6), 80 * k);
    expect(StreamCacheServer.seekPartBytes(11), 80 * k);
    expect(StreamCacheServer.seekPartBytes(12), 112 * k);
    var last = 0;
    for (var i = 0; i < 200; i++) {
      final b = StreamCacheServer.seekPartBytes(i);
      expect(b, greaterThanOrEqualTo(last), reason: 'part $i');
      expect(b % (16 * k), 0, reason: 'part $i');
      last = b;
    }
    expect(last, 2 * mb);
    // On a faster line the first round starts bigger.
    expect(StreamCacheServer.seekPartBytes(0, first: 512 * k), 512 * k);
  });

  test('a fragmented film\'s seek and its jump back ask for no byte twice', () async {
    // The player seeks into a fragment, reads its header, opens a request
    // for the fragment before (for its sound) and only then closes the
    // first — and reads on from there straight through the bytes it left.
    StreamCacheServer.lanes = 6;
    up.piece = 16 * 1024;
    up.pace = const Duration(milliseconds: 40);
    const x = 33 * mb, gap = 180 * 1024, y = x - gap;
    final saved = {for (final at in [x, y]) at: Uint8List.fromList(up.body.sublist(at, at + 8))};
    for (final at in [x, y]) {
      up.body.setRange(at + 4, at + 8, 'moof'.codeUnits);
    }
    try {
      final local = await StreamCacheServer.instance.localUrlFor(
          cacheId: 'film-frag', upstream: up.url('t1'), refresh: () async => null);
      await Future<void>.delayed(const Duration(milliseconds: 300)); // the length check
      up.ranges.clear();
      final first = HttpClient();
      Future<Uint8List> back;
      try {
        final r = await first.getUrl(Uri.parse(local!));
        r.headers.set(HttpHeaders.rangeHeader, 'bytes=$x-');
        final resp = await r.close();
        var got = 0;
        await for (final chunk in resp) {
          got += chunk.length;
          if (got >= 16 * 1024) break;
        }
        // A fragment header where the stretch began: every lane at once.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(up.ranges.where((r) => r.$1 >= x).length, 6,
            reason: 'lanes opened on the fragment header: ${up.ranges}');
        back = _get(local, from: y, take: gap + 600 * 1024);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      } finally {
        first.close(force: true);
      }
      final got = await back.timeout(const Duration(seconds: 20));
      expect(got, Uint8List.sublistView(up.body, y, y + gap + 600 * 1024));
      final asked = up.ranges.toList()..sort((a, b) => a.$1.compareTo(b.$1));
      for (var i = 1; i < asked.length; i++) {
        expect(asked[i].$1, greaterThan(asked[i - 1].$2),
            reason: 'asked for twice: $asked');
      }
    } finally {
      saved.forEach((at, b) => up.body.setRange(at, at + 8, b));
      StreamCacheServer.instance.release('film-frag');
    }
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
