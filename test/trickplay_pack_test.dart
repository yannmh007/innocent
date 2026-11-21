import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/trickplay_pack.dart';

import 'support/itp1.dart';

/// The seek bar's pictures made in advance: the app's reader of an `ITP1`
/// pack (docs/trickplay_plan.md; tool/trickplay.py is the layout's
/// reference). Every picture here is made up — a JPEG's first and last
/// markers around a few bytes — never a film's.

TrickplayInfo infoFor(Uint8List pack,
        {int intervalMs = 4000, int width = 320, int height = 180, int? count, int? bytes}) =>
    TrickplayInfo(
      url: 'https://w.example/v/tok',
      bytes: bytes ?? pack.length,
      intervalMs: intervalMs,
      width: width,
      height: height,
      count: count ?? ByteData.sublistView(pack).getUint32(16),
    );

/// A pack served from memory, each read counted.
class _Served {
  _Served(this.bytes);
  Uint8List bytes;
  final List<(int, int)> reads = <(int, int)>[];
  bool fail = false;

  Future<Uint8List?> read(int a, int b) async {
    reads.add((a, b));
    if (fail) return null;
    if (a >= bytes.length) return null;
    return Uint8List.sublistView(bytes, a, b > bytes.length ? bytes.length : b);
  }
}

Uint8List _hex(String h) =>
    Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

void main() {
  // tool/trickplay.py's pack() of three made-up pictures at 4 s, 320x180:
  // python3 -c "import trickplay; trickplay.pack([b'\xff\xd8\xff\xe0' +
  // bytes([i]*n) + b'\xff\xd9' for i, n in ((1,3),(2,5),(3,1))], 4000, 320,
  // 180, 'jpeg')" — the reference's own bytes.
  const reference = '495450310001000100000fa0014000b4000000030000002800000028000000310000003c00000043'
      'ffd8ffe0010101ffd9ffd8ffe00202020202ffd9ffd8ffe003ffd9';

  group('the layout', () {
    test('this test builds the bytes tool/trickplay.py builds', () {
      final ours = buildPack([fakeJpeg(1, 3), fakeJpeg(2, 5), fakeJpeg(3, 1)]);
      expect(ours, _hex(reference));
    });

    test('the reference pack reads: offsets, pictures, header = grant', () async {
      final data = _hex(reference);
      final (h, why) = TrickplayHeader.parse(data, infoFor(data));
      expect(why, 'ok');
      expect(h!.offsets, <int>[40, 49, 60, 67]);
      final pack = TrickplayPack(infoFor(data), _Served(data).read);
      expect(await pack.picture(1), fakeJpeg(2, 5));
    });
  });

  group('a pack is used only if it is the one the grant names', () {
    final good = buildPack(List<Uint8List>.generate(10, (i) => fakeJpeg(i, 50 + i)));

    test('cut short inside the header or the offsets', () {
      expect(TrickplayHeader.parse(Uint8List.sublistView(good, 0, 20), infoFor(good)).$2,
          'cut short inside the header');
      expect(TrickplayHeader.parse(Uint8List.sublistView(good, 0, 40), infoFor(good)).$2,
          'cut short inside the offsets');
    });

    test('a pack cut short on the server: its reads fail, then it is given up', () async {
      final served = _Served(Uint8List.sublistView(good, 0, 30));
      final pack = TrickplayPack(infoFor(good), served.read);
      for (var i = 0; i < TrickplayPack.giveUpAfter; i++) {
        expect(await pack.picture(0), isNull);
      }
      expect(pack.usable, isFalse);
      final asked = served.reads.length;
      expect(await pack.picture(0), isNull);
      expect(served.reads.length, asked, reason: 'not asked again once given up');
    });

    test('the wrong magic', () async {
      final foreign = Uint8List.fromList(good)..setAll(0, 'RIFF'.codeUnits);
      final pack = TrickplayPack(infoFor(foreign), _Served(foreign).read);
      expect(await pack.open(), isFalse);
      expect(pack.broken, 'not an ITP1 pack');
      expect(pack.usable, isFalse);
    });

    test('another version or codec', () {
      final v2 = buildPack([fakeJpeg(1, 9)], version: 2);
      expect(TrickplayHeader.parse(v2, infoFor(v2)).$2, 'version 2');
      final webp = buildPack([fakeJpeg(1, 9)], codec: 2);
      expect(TrickplayHeader.parse(webp, infoFor(webp)).$2, 'codec 2');
    });

    test('offsets that go back, or start or end in the wrong place', () {
      final back = Uint8List.fromList(good);
      final b = ByteData.sublistView(back);
      b.setUint32(24 + 4 * 3, b.getUint32(24 + 4 * 2) - 1);
      expect(TrickplayHeader.parse(back, infoFor(back)).$2, 'offsets out of order');
      final same = Uint8List.fromList(good);
      final s = ByteData.sublistView(same);
      s.setUint32(24 + 4 * 3, s.getUint32(24 + 4 * 2));
      expect(TrickplayHeader.parse(same, infoFor(same)).$2, 'offsets out of order');
      final first = Uint8List.fromList(good);
      ByteData.sublistView(first).setUint32(24, 100);
      expect(TrickplayHeader.parse(first, infoFor(first)).$2, 'first offset not at the header end');
      expect(TrickplayHeader.parse(good, infoFor(good, bytes: good.length + 1)).$2,
          'last offset not at the end');
      final len = Uint8List.fromList(good);
      ByteData.sublistView(len).setUint32(20, 999);
      expect(TrickplayHeader.parse(len, infoFor(len)).$2, 'header length 999');
    });

    test('a header that is not the grant: interval, size or count', () {
      for (final info in [
        infoFor(good, intervalMs: 5000),
        infoFor(good, width: 224),
        infoFor(good, height: 134),
        infoFor(good, count: 11),
      ]) {
        expect(TrickplayHeader.parse(good, info).$2, 'header and grant differ');
      }
    });

    test('a slice that is not a JPEG is never handed out', () async {
      final bad = buildPack([fakeJpeg(1, 9), Uint8List.fromList(List<int>.filled(12, 7)), fakeJpeg(3, 9)]);
      final pack = TrickplayPack(infoFor(bad), _Served(bad).read);
      expect(await pack.picture(1), isNull);
      expect(await pack.picture(2), fakeJpeg(3, 9));
    });
  });

  group('reading', () {
    // A film of 600 pictures (40 min at 4 s): a header of 2.4 KB.
    final pictures = List<Uint8List>.generate(600, (i) => fakeJpeg(i, 3000 + (i * 37) % 2000));
    final film = buildPack(pictures);

    test('the first read is [0, 16 KB): the header and every offset at once', () async {
      final served = _Served(film);
      final pack = TrickplayPack(infoFor(film), served.read);
      expect(await pack.open(), isTrue);
      expect(served.reads.single, (0, TrickplayPack.firstRead));
      expect(pack.headerMs, isNotNull);
    });

    test('a header bigger than 16 KB is read whole in that first request', () async {
      final long = buildPack(List<Uint8List>.generate(5000, (i) => fakeJpeg(i, 8)));
      final served = _Served(long);
      final pack = TrickplayPack(infoFor(long), served.read);
      expect(await pack.open(), isTrue);
      expect(served.reads.single, (0, 24 + 4 * 5001));
    });

    test('a pack smaller than 16 KB: the first read stops at its end', () async {
      final tiny = buildPack([fakeJpeg(1, 9), fakeJpeg(2, 9)]);
      final served = _Served(tiny);
      final pack = TrickplayPack(infoFor(tiny), served.read);
      expect(await pack.open(), isTrue);
      expect(served.reads.single, (0, tiny.length));
    });

    test('picture ⌊at / interval⌋, within [0, count - 1]', () async {
      final pack = TrickplayPack(infoFor(film), _Served(film).read);
      expect(pack.indexAt(Duration.zero), 0);
      expect(pack.indexAt(const Duration(milliseconds: 3999)), 0);
      expect(pack.indexAt(const Duration(seconds: 4)), 1);
      expect(pack.indexAt(const Duration(seconds: 579)), 144);
      expect(pack.indexAt(const Duration(hours: 9)), 599, reason: 'past the end: the last');
      expect(pack.indexAt(const Duration(seconds: -3)), 0);
      expect(await pack.pictureAt(const Duration(seconds: 579)), pictures[144]);
      expect(await pack.pictureAt(const Duration(hours: 9)), pictures[599]);
    });

    test('one picture is one range of exactly its bytes; held after', () async {
      final served = _Served(film);
      final pack = TrickplayPack(infoFor(film), served.read);
      await pack.open();
      final h = TrickplayHeader.parse(film, infoFor(film)).$1!;
      expect(await pack.picture(300), pictures[300]);
      expect(served.reads.last, (h.offsets[300], h.offsets[301]));
      final n = served.reads.length;
      expect(await pack.picture(300), pictures[300]);
      expect(served.reads.length, n, reason: 'from memory');
    });

    test('a run of neighbours is ONE request; the ends already held are not asked again', () async {
      final served = _Served(film);
      final pack = TrickplayPack(infoFor(film), served.read);
      await pack.open();
      final h = TrickplayHeader.parse(film, infoFor(film)).$1!;
      await pack.picture(90);
      await pack.picture(110);
      served.reads.clear();
      expect(await pack.takeRun(90, 110), 19);
      expect(served.reads.single, (h.offsets[91], h.offsets[110]));
      for (var i = 90; i <= 110; i++) {
        expect(pack.held(i), pictures[i]);
      }
      served.reads.clear();
      expect(await pack.takeRun(-5, 3), 4, reason: 'clamped to the film');
      expect(served.reads.single, (h.offsets[0], h.offsets[4]));
      expect(await pack.takeRun(598, 700), 2);
      served.reads.clear();
      expect(await pack.takeRun(95, 105), 0);
      expect(served.reads, isEmpty, reason: 'all held: nothing asked');
    });

    test('a picture inside a run on its way waits for it, not a request of its own', () async {
      final served = _Served(film);
      final pack = TrickplayPack(infoFor(film), served.read);
      await pack.open();
      served.reads.clear();
      final run = pack.takeRun(200, 220);
      final one = pack.picture(210);
      expect(await one, pictures[210]);
      expect(await run, 21);
      expect(served.reads.length, 1);
    });

    test('the LRU stays within its bytes, the most recent kept', () async {
      final served = _Served(film);
      final pack = TrickplayPack(infoFor(film), served.read, cacheBytes: 64 * 1024);
      await pack.takeRun(0, 59);
      expect(pack.heldBytes, lessThanOrEqualTo(64 * 1024));
      expect(pack.held(59), pictures[59]);
      expect(pack.held(0), isNull, reason: 'the oldest went first');
      // A picture read again moves to the front.
      pack.held(50);
      await pack.takeRun(100, 105);
      expect(pack.held(50), pictures[50], reason: 'touched last before the run');
      expect(pack.held(51), isNull, reason: 'older than 50 now, and gone');
      expect(pack.held(105), pictures[105]);
      expect(pack.heldBytes, lessThanOrEqualTo(64 * 1024));
    });

    test('a whole film at the default LRU stays within ~2 MB', () async {
      final pack = TrickplayPack(infoFor(film), _Served(film).read);
      for (var i = 0; i < 600; i += 20) {
        await pack.takeRun(i, i + 19);
      }
      expect(pack.heldBytes, lessThanOrEqualTo(2 * 1024 * 1024));
      expect(pack.heldBytes, greaterThan(1024 * 1024));
    });

    test('nearest held picture within a reach', () async {
      final pack = TrickplayPack(infoFor(film), _Served(film).read);
      await pack.picture(100);
      await pack.picture(104);
      expect(pack.nearestHeld(103, 2)!.$1, 104);
      expect(pack.nearestHeld(101, 2)!.$1, 100);
      expect(pack.nearestHeld(110, 2), isNull);
    });

    test('a failed read is no picture, then the pack is given up after three', () async {
      final served = _Served(film);
      final pack = TrickplayPack(infoFor(film), served.read);
      await pack.open();
      served.fail = true;
      expect(await pack.picture(5), isNull);
      expect(pack.usable, isTrue, reason: 'one failure is not the end');
      served.fail = false;
      expect(await pack.picture(5), pictures[5]);
      served.fail = true;
      for (var i = 0; i < TrickplayPack.giveUpAfter; i++) {
        expect(await pack.picture(10 + i), isNull);
      }
      expect(pack.usable, isFalse);
    });

    test('a read that never answers counts as failed, not a hang', () async {
      final keep = TrickplayPack.readTimeout;
      TrickplayPack.readTimeout = const Duration(milliseconds: 300);
      try {
        final pack = TrickplayPack(infoFor(film), (a, b) => Completer<Uint8List?>().future);
        expect(await pack.open(), isFalse);
        expect(pack.usable, isTrue, reason: 'one failure is not the end');
      } finally {
        TrickplayPack.readTimeout = keep;
      }
    });

    test('a read that throws is a failed read, not an error', () async {
      final pack = TrickplayPack(infoFor(film), (a, b) async => throw StateError('line'));
      expect(await pack.open(), isFalse);
      expect(pack.usable, isTrue);
    });
  });

  group('the grant field', () {
    Map<String, Object?> field() => <String, Object?>{
          'url': 'https://w.example/v/tok',
          'bytes': 600000,
          'interval_ms': 4000,
          'width': 320,
          'height': 180,
          'count': 150,
          'codec': 'jpeg',
        };

    test('a whole field reads', () {
      final t = TrickplayInfo.fromJson(field())!;
      expect(t.count, 150);
      expect(t.intervalMs, 4000);
      expect(t.headerLength, 24 + 4 * 151);
    });

    test('no field, or one this build does not take, is no pack', () {
      expect(TrickplayInfo.fromJson(null), isNull);
      expect(TrickplayInfo.fromJson('x'), isNull);
      for (final (k, v) in <(String, Object?)>[
        ('codec', 'webp'),
        ('codec', null),
        ('url', null),
        ('url', ''),
        ('count', 0),
        ('count', -1),
        ('interval_ms', 0),
        ('bytes', 0),
        ('bytes', null),
        ('width', 0),
        ('height', -2),
        ('count', '150'),
        ('count', 1.5),
        ('count', 200000),
        ('count', double.infinity),
        ('bytes', double.nan),
        ('bytes', 24 + 4 * 151),
        ('seal', <String, Object?>{'v': 1}),
      ]) {
        final f = field()..[k] = v;
        expect(TrickplayInfo.fromJson(f), isNull, reason: '$k = $v');
      }
    });

    test('the same pack renewed, or another one', () {
      final a = TrickplayInfo.fromJson(field())!;
      final b = TrickplayInfo.fromJson(field()..['url'] = 'https://w.example/v/tok2')!;
      final c = TrickplayInfo.fromJson(field()..['bytes'] = 600001)!;
      expect(a.sameObjectAs(b), isTrue);
      expect(a.sameObjectAs(c), isFalse);
    });
  });

  group('where the seek bar\'s picture comes from', () {
    final film = buildPack(List<Uint8List>.generate(100, (i) => fakeJpeg(i, 40)));
    final fragmentPicture = fakeJpeg(0xEE, 20);

    test('the pack when it gives one; no fragment fetched', () async {
      final pack = TrickplayPack(infoFor(film), _Served(film).read);
      var fragments = 0;
      final (pic, from) = await SeekPreviewSource.picture(pack, const Duration(seconds: 41), () async {
        fragments++;
        return fragmentPicture;
      });
      expect(from, 'pack');
      expect(pic, fakeJpeg(10, 40));
      expect(fragments, 0);
    });

    test('no pack: the fragment, as before', () async {
      final (pic, from) =
          await SeekPreviewSource.picture(null, const Duration(seconds: 41), () async => fragmentPicture);
      expect(from, 'fragment');
      expect(pic, fragmentPicture);
    });

    test('a read that fails, or a pack found wrong: the fragment, silently', () async {
      final served = _Served(film)..fail = true;
      final failing = TrickplayPack(infoFor(film), served.read);
      final (pic, from) =
          await SeekPreviewSource.picture(failing, const Duration(seconds: 41), () async => fragmentPicture);
      expect((pic, from), (fragmentPicture, 'fragment'));
      final wrong = TrickplayPack(infoFor(film, count: 99), _Served(film).read);
      final (pic2, from2) =
          await SeekPreviewSource.picture(wrong, const Duration(seconds: 41), () async => fragmentPicture);
      expect((pic2, from2), (fragmentPicture, 'fragment'));
      expect(wrong.usable, isFalse);
      final (pic3, from3) = await SeekPreviewSource.picture(wrong, Duration.zero, () async => null);
      expect((pic3, from3), (null, null));
    });

    test('ahead: the pack run, the fragments without a pack, NOTHING with the data saver', () {
      final pack = TrickplayPack(infoFor(film), _Served(film).read);
      expect(SeekPreviewSource.ahead(pack: pack, saving: false), PreviewAhead.packRun);
      expect(SeekPreviewSource.ahead(pack: pack, saving: true), PreviewAhead.none);
      expect(SeekPreviewSource.ahead(pack: null, saving: false), PreviewAhead.fragments);
      // The owner's choice of 21 Nov 2026 (B3): a film without a pack took
      // six fragments ahead (~450 KB) each time the controls came up, data
      // saver or not; now nothing, as with a pack.
      expect(SeekPreviewSource.ahead(pack: null, saving: true), PreviewAhead.none,
          reason: 'the data saver takes nothing ahead, pack or not');
    });

    test('ahead on a single file (no ladder, no fragments): the pack run or nothing', () {
      final pack = TrickplayPack(infoFor(film), _Served(film).read);
      expect(SeekPreviewSource.ahead(pack: pack, saving: false, fragments: false), PreviewAhead.packRun);
      expect(SeekPreviewSource.ahead(pack: pack, saving: true, fragments: false), PreviewAhead.none);
      expect(SeekPreviewSource.ahead(pack: null, saving: false, fragments: false), PreviewAhead.none);
      expect(SeekPreviewSource.ahead(pack: null, saving: true, fragments: false), PreviewAhead.none);
    });

    test('the data saver: only the picture under the finger is read', () async {
      final served = _Served(film);
      final pack = TrickplayPack(infoFor(film), served.read);
      // The controls come up: nothing.
      expect(SeekPreviewSource.ahead(pack: pack, saving: true), PreviewAhead.none);
      expect(served.reads, isEmpty);
      // A drag: the header, then the picture alone.
      await SeekPreviewSource.picture(pack, const Duration(seconds: 200), () async => null);
      expect(served.reads.length, 2);
      expect(pack.heldCount, 1);
    });

    test('the run ahead is 40 s either side: 21 pictures at 4 s, one request', () async {
      final served = _Served(film);
      final pack = TrickplayPack(infoFor(film), served.read);
      final (a, b) = SeekPreviewSource.runAround(pack, const Duration(seconds: 200));
      expect((a, b), (40, 60));
      await pack.open();
      served.reads.clear();
      expect(await pack.takeRun(a, b), 21);
      expect(served.reads.length, 1);
      final slow = TrickplayPack(infoFor(film, intervalMs: 60000), _Served(film).read);
      expect(SeekPreviewSource.runAround(slow, const Duration(minutes: 5)), (4, 6),
          reason: 'never less than one either side');
    });
  });
  group('a film played as one file (FilePacks)', () {
    TrickplayInfo info(String url) =>
        TrickplayInfo(url: url, bytes: 9000, intervalMs: 4000, width: 320, height: 180, count: 59);

    test('every copy of the film names the same pack; another film clears the last', () {
      final arms = FilePacks();
      final a = info('https://w/a');
      arms.arm('http://127.0.0.1:1/c/t/hero-0', FilePackArm(pack: a, packAt: 'pack:hero'));
      arms.arm('http://127.0.0.1:1/c/t/hero-240', FilePackArm(pack: a, packAt: 'pack:hero', saving: true));
      expect(arms['http://127.0.0.1:1/c/t/hero-0']?.packAt, 'pack:hero');
      expect(arms['http://127.0.0.1:1/c/t/hero-240']?.saving, isTrue);
      expect(arms.has('http://127.0.0.1:1/c/t/hero-240'), isTrue);
      // The next film: never Hero's pictures over its address, nor Hero's
      // pack left armed for an address that comes back.
      arms.arm('http://127.0.0.1:1/c/t/ed-0', FilePackArm(pack: info('https://w/b'), packAt: 'pack:ed'));
      expect(arms['http://127.0.0.1:1/c/t/hero-0'], isNull);
      expect(arms['http://127.0.0.1:1/c/t/hero-240'], isNull);
      expect(arms['http://127.0.0.1:1/c/t/ed-0']?.packAt, 'pack:ed');
    });

    test('an address armed again takes the new grant\'s pack', () {
      final arms = FilePacks();
      arms.arm('u', FilePackArm(pack: info('https://w/old'), packAt: 'pack:ed'));
      final fresh = info('https://w/new');
      arms.arm('u', FilePackArm(pack: fresh, packAt: 'pack:ed'));
      expect(identical(arms['u']?.pack, fresh), isTrue);
    });

    test('nothing for an address never armed, a null one, or after clear', () {
      final arms = FilePacks();
      expect(arms[null], isNull);
      expect(arms.has(null), isFalse);
      expect(arms['file:///sdcard/a.mp4'], isNull);
      arms.arm('u', FilePackArm(pack: info('https://w/a'), packAt: 'pack:x'));
      arms.clear();
      expect(arms['u'], isNull);
    });
  });
}
