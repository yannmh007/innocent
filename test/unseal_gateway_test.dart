// The unseal gateway (lib/features/video_hub/data/seal/unseal_gateway.dart):
// a sealed object behind a stand-in Worker, read through the gateway as the
// plain film — every range exact, nothing fetched twice for neighbours, an
// expired link and "slow down" passed back as the proxy expects, a segment
// that does not open fetched once more and never passed on.
//
// The cipher is test/support/seal_test_cipher.dart, which first proves it
// seals the shared vectors (Tink opens them) byte for byte.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/seal/media_seal.dart';
import 'package:innocent/features/video_hub/data/seal/media_seal_layout.dart';
import 'package:innocent/features/video_hub/data/seal/unseal_gateway.dart';

import 'support/fake_sealed_worker.dart';
import 'support/seal_test_cipher.dart';

Future<(int, Map<String, String>, Uint8List)> fetch(String url, {String? range}) async {
  final c = HttpClient();
  try {
    final r = await c.getUrl(Uri.parse(url));
    if (range != null) r.headers.set(HttpHeaders.rangeHeader, range);
    final resp = await r.close();
    final headers = <String, String>{};
    resp.headers.forEach((k, v) => headers[k] = v.join(','));
    final b = BytesBuilder(copy: false);
    try {
      await for (final c in resp) {
        b.add(c);
      }
    } catch (_) {}
    return (resp.statusCode, headers, b.takeBytes());
  } finally {
    c.close(force: true);
  }
}

void main() {
  test('the test cipher seals the shared vectors byte for byte (Tink opens them)', () {
    final raw = jsonDecode(File('test/fixtures/media_seal_vectors.json').readAsStringSync()) as List;
    var checked = 0;
    for (final v in raw.cast<Map<String, dynamic>>()) {
      final n = v['plain_size'] as int;
      if (n > 200000) continue; // the slow cipher; the JVM checks the rest
      final plain = vectorPlain(n, v['seed'] as String);
      expect(sha256.convert(plain).toString(), v['plain_sha256']);
      final sealed = sealObject(unhex(v['dek'] as String), v['dek_id'] as String, plain,
          salt: unhex(v['salt'] as String), prefix: unhex(v['prefix'] as String));
      expect(sealed.length, v['sealed_size'], reason: 'size $n');
      expect(sha256.convert(sealed).toString(), v['sealed_sha256'], reason: 'bytes $n');
      checked++;
    }
    expect(checked, 8);
  });

  group('gateway', () {
    late FakeWorker worker;
    late TestSealCipher cipher;
    late UnsealGateway gw;
    late Uint8List plain;
    late SealGrant seal;
    late String upstream;
    final rnd = Random(7);

    Uint8List bytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));

    Future<void> setUpObject(int n, {bool header = true}) async {
      plain = bytes(n);
      final dek = bytes(32);
      final salt = bytes(32), prefix = bytes(7);
      final sealed = sealObject(dek, 'dek-test', plain, salt: salt, prefix: prefix);
      worker = FakeWorker(sealed);
      upstream = await worker.start();
      seal = SealGrant(
        dekId: 'dek-test',
        plainSize: n,
        sealedSize: sealed.length,
        wrap: 'tls',
        dek: base64Encode(dek),
        header: header ? Uint8List.sublistView(sealed, 0, 40) : null,
      );
      cipher = TestSealCipher();
      gw = UnsealGateway(cipher: cipher);
    }

    tearDown(() async {
      await gw.shutdown();
      await worker.stop();
    });

    test('any range is the film\'s own bytes, with the film\'s own length', () async {
      const n = MediaSealLayout.firstPlain + 5 * MediaSealLayout.plainSegment + 1234;
      await setUpObject(n);
      final url = (await gw.urlFor(id: 'a', upstream: upstream, seal: seal))!;
      final edges = <(int, int)>[
        (0, 0), (0, 8191), (0, n - 1), (n - 1, n - 1),
        (MediaSealLayout.firstPlain - 1, MediaSealLayout.firstPlain),
        (MediaSealLayout.firstPlain, MediaSealLayout.firstPlain + MediaSealLayout.plainSegment - 1),
        (100000, 100000), (n - 70000, n - 1),
      ];
      for (var k = 0; k < 40; k++) {
        final a = rnd.nextInt(n);
        edges.add((a, min(n - 1, a + rnd.nextInt(200000))));
      }
      for (final (a, b) in edges) {
        final (code, h, body) = await fetch(url, range: 'bytes=$a-$b');
        expect(code, 206, reason: '$a-$b');
        expect(h['content-range'], 'bytes $a-$b/$n');
        expect(body, plain.sublist(a, b + 1), reason: '$a-$b');
      }
      final (c2, _, all) = await fetch(url);
      expect(c2, 200);
      expect(all, plain);
      final (c3, h3, _) = await fetch(url, range: 'bytes=$n-');
      expect(c3, 416);
      expect(h3['content-range'], 'bytes */$n');
      expect(cipher.registers, 1, reason: 'the DEK is handed over once');
      expect(worker.headerRequests, 0, reason: 'the grant carried the header');
    });

    test('neighbours share a segment: each is fetched once', () async {
      const n = MediaSealLayout.firstPlain + 12 * MediaSealLayout.plainSegment;
      await setUpObject(n);
      final url = (await gw.urlFor(id: 'b', upstream: upstream, seal: seal))!;
      // Six lanes at once, split at points inside segments.
      const part = 100000;
      final got = await Future.wait([
        for (var k = 0; k < 6; k++) fetch(url, range: 'bytes=${k * part}-${(k + 1) * part - 1}'),
      ]);
      for (var k = 0; k < 6; k++) {
        expect(got[k].$3, plain.sublist(k * part, (k + 1) * part));
      }
      final need = MediaSealLayout.spanFor(0, 6 * part - 1, n);
      expect(worker.bytesSent, need.end - need.start, reason: 'no segment fetched twice');
      // Read again at once: the last ones opened are still here.
      final before = worker.requests;
      final (_, _, again) = await fetch(url, range: 'bytes=${5 * part}-${6 * part - 1}');
      expect(again, plain.sublist(5 * part, 6 * part));
      expect(worker.requests, before, reason: 'served from what was just opened');
    });

    test('no header in the grant: read from the object, once', () async {
      await setUpObject(300000, header: false);
      final url = (await gw.urlFor(id: 'c', upstream: upstream, seal: seal))!;
      final (code, _, body) = await fetch(url, range: 'bytes=200000-250000');
      expect(code, 206);
      expect(body, plain.sublist(200000, 250001));
      final (_, _, b2) = await fetch(url, range: 'bytes=10-20');
      expect(b2, plain.sublist(10, 21));
      expect(worker.headerRequests, 1);
    });

    test('an expired link and "slow down" are passed back; a renewed link plays', () async {
      await setUpObject(200000);
      final url = (await gw.urlFor(id: 'd', upstream: upstream, seal: seal))!;
      worker.refuse.add((403, null));
      expect((await fetch(url, range: 'bytes=0-99')).$1, 403);
      worker.refuse.add((429, '2'));
      final (c429, h429, _) = await fetch(url, range: 'bytes=0-99');
      expect(c429, 429);
      expect(h429['retry-after'], '2');
      worker.refuse.add((503, null));
      expect((await fetch(url, range: 'bytes=0-99')).$1, 502);
      expect(gw.update('d', '$upstream?renewed', seal), isTrue);
      final (ok, _, body) = await fetch(url, range: 'bytes=0-99');
      expect(ok, 206);
      expect(body, plain.sublist(0, 100));
      expect(worker.ranges.length, 4);
      // Another object under the same id is not a renewal.
      final other = SealGrant(
          dekId: 'other', plainSize: seal.plainSize, sealedSize: seal.sealedSize, wrap: 'tls', dek: seal.dek);
      expect(gw.update('d', upstream, other), isFalse);
    });

    test('a segment that does not open is fetched once more; twice, never passed on', () async {
      const n = MediaSealLayout.firstPlain + 3 * MediaSealLayout.plainSegment;
      await setUpObject(n);
      final url = (await gw.urlFor(id: 'e', upstream: upstream, seal: seal))!;
      worker
        ..corruptAt = 2 * MediaSealLayout.segment + 100
        ..corruptTimes = 1;
      final (code, _, body) = await fetch(url, range: 'bytes=0-${n - 1}');
      expect(code, 206);
      expect(body, plain, reason: 'the second fetch opened');
      expect(UnsealGateway.refetches, greaterThanOrEqualTo(1));

      final gw2 = UnsealGateway(cipher: TestSealCipher());
      final url2 = (await gw2.urlFor(id: 'e2', upstream: upstream, seal: seal))!;
      worker
        ..corruptAt = MediaSealLayout.segment + 7
        ..corruptTimes = 2;
      final (c2, _, b2) = await fetch(url2, range: 'bytes=${MediaSealLayout.firstPlain}-${n - 1}');
      expect(c2, 502, reason: 'the first segment never opened: refused before a byte');
      expect(b2, isEmpty);
      worker
        ..corruptAt = 2 * MediaSealLayout.segment + 7
        ..corruptTimes = 2;
      final (c3, _, b3) = await fetch(url2, range: 'bytes=0-${n - 1}');
      expect(c3, 206);
      // Cut short where the bad segment begins: every byte sent is right.
      expect(b3.length, lessThan(n));
      expect(b3, plain.sublist(0, b3.length));
      await gw2.shutdown();
    });

    test('a key that does not register: refused, nothing passed on', () async {
      await setUpObject(100000);
      cipher.refuseRegister = true;
      final gw3 = UnsealGateway(cipher: cipher);
      final url = (await gw3.urlFor(id: 'f', upstream: upstream, seal: seal))!;
      final (code, _, body) = await fetch(url, range: 'bytes=0-999');
      expect(code, 502);
      expect(body, isEmpty);
      await gw3.shutdown();
    });

    test('a Worker that names another size is not this object', () async {
      await setUpObject(100000);
      worker.claimTotal = seal.sealedSize + 16;
      final url = (await gw.urlFor(id: 'g', upstream: upstream, seal: seal))!;
      expect((await fetch(url, range: 'bytes=0-999')).$1, 502);
    });

    test('the proxy letting go stops the Worker\'s fetch', () async {
      const n = MediaSealLayout.firstPlain + 60 * MediaSealLayout.plainSegment;
      await setUpObject(n);
      worker.trickle = 400 * 1024;
      final url = (await gw.urlFor(id: 'h', upstream: upstream, seal: seal))!;
      final c = HttpClient();
      final r = await c.getUrl(Uri.parse(url));
      r.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${n - 1}');
      final resp = await r.close();
      expect(resp.statusCode, 206);
      var got = 0;
      final first = Completer<void>();
      final sub = resp.listen((chunk) {
        got += chunk.length;
        if (got > 200000 && !first.isCompleted) first.complete();
      });
      await first.future;
      final s = await resp.detachSocket();
      s.destroy();
      await sub.cancel();
      c.close(force: true);
      final sentAtCut = worker.bytesSent;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(worker.bytesSent - sentAtCut, lessThan(400 * 1024),
          reason: 'the Worker stopped within about a second of the hang-up');
      expect(worker.bytesSent, lessThan(seal.sealedSize ~/ 2));
    });

    // A jump inside another read: the player skips ahead into bytes the
    // read before is still bringing, far off. The new request must not wait
    // for the old read to reach them (device lab run 41293034978: skip+30
    // waited 3.9 s for its first byte at 240p).
    test('a jump far inside another read does not wait for it', () async {
      const n = MediaSealLayout.firstPlain + 40 * MediaSealLayout.plainSegment;
      await setUpObject(n);
      worker.trickle = 256 * 1024;
      final url = (await gw.urlFor(id: 'j', upstream: upstream, seal: seal))!;
      final c = HttpClient();
      final r = await c.getUrl(Uri.parse(url));
      r.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${2 * 1024 * 1024 - 1}');
      final resp = await r.close();
      expect(resp.statusCode, 206);
      var got = 0;
      final first = Completer<void>();
      final sub = resp.listen((chunk) {
        got += chunk.length;
        if (got > 70000 && !first.isCompleted) first.complete();
      });
      await first.future;
      // As the proxy ends a fill: the subscription cancelled.
      await sub.cancel();
      final sentAtCut = worker.bytesSent;
      // 1.5 MB in: some 5 s of the old read away at this speed.
      const a = 1500 * 1000, b = a + 90000;
      final clock = Stopwatch()..start();
      final (code, _, body) = await fetch(url, range: 'bytes=$a-$b');
      expect(code, 206);
      expect(body, plain.sublist(a, b + 1));
      expect(clock.elapsedMilliseconds, lessThan(2500),
          reason: 'its own read, not the end of the old one');
      // And the old read stopped once its reader had gone.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final since = worker.bytesSent - sentAtCut;
      expect(since, lessThan(2 * (b - a) + 512 * 1024), reason: 'the old read is not read on to its end');
      c.close(force: true);
    });

    // A lane and the next: the next starts inside the segment the first
    // ends in, a long way ahead of the first's progress. The next is not
    // made to wait for the whole of the first (the proxy's and the
    // downloader's timers would take that for a dead lane).
    test('a lane\'s neighbour starting in its last segment is not held behind it', () async {
      const n = MediaSealLayout.firstPlain + 40 * MediaSealLayout.plainSegment;
      await setUpObject(n);
      worker.trickle = 256 * 1024;
      final url = (await gw.urlFor(id: 'k', upstream: upstream, seal: seal))!;
      const split = 1000 * 1000;
      final lane1 = fetch(url, range: 'bytes=0-${split - 1}');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final clock = Stopwatch()..start();
      final c = HttpClient();
      final r = await c.getUrl(Uri.parse(url));
      r.headers.set(HttpHeaders.rangeHeader, 'bytes=$split-${split + 200000}');
      final resp = await r.close();
      final answered = clock.elapsedMilliseconds;
      final b = BytesBuilder(copy: false);
      await for (final ch in resp) {
        b.add(ch);
      }
      expect(resp.statusCode, 206);
      expect(b.takeBytes(), plain.sublist(split, split + 200001));
      expect(answered, lessThan(1500), reason: 'answered on its own fetch, not after the first lane');
      final (_, _, one) = await lane1;
      expect(one, plain.sublist(0, split));
      c.close(force: true);
    });

    test('a malformed seal block is refused', () {
      final ok = <String, dynamic>{
        'v': 1, 'dek_id': 'x', 'plain_size': 100, 'sealed_size': MediaSealLayout.sealedSize(100),
        'wrap': 'rsa', 'dek': 'AAAA',
      };
      expect(SealGrant.fromJson(ok), isNotNull);
      expect(SealGrant.fromJson({...ok, 'v': 2}), isNull);
      expect(SealGrant.fromJson({...ok, 'sealed_size': 100}), isNull, reason: 'sizes that disagree');
      expect(SealGrant.fromJson({...ok, 'wrap': 'plain'}), isNull);
      expect(SealGrant.fromJson({...ok, 'dek': ''}), isNull);
      expect(SealGrant.fromJson({...ok, 'header': base64Encode(List<int>.filled(40, 0))}), isNull,
          reason: 'a header that is not a seal header');
      expect(SealGrant.fromJson('x'), isNull);
    });
  });
}
