import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/cmaf_index.dart';

import 'support/cmaf.dart';

void main() {
  final film = FakeCmaf.build();
  Uint8List head([int? n]) =>
      Uint8List.sublistView(film.bytes, 0, n ?? film.headEnd + 16);

  test('reads every fragment: where it starts, how big, when', () {
    final idx = CmafIndex.parse(head())!;
    expect(idx.length, 30);
    expect(idx.starts, film.fragmentStarts);
    expect(idx.sizes, film.fragmentSizes);
    expect(idx.timesMs.first, 0);
    expect(idx.timesMs[1], 2000);
    expect(idx.timesMs.last, 60000);
  });

  test('says where the index ends, so the head can be read in one go', () {
    expect(CmafIndex.headBytes(head()), film.headEnd);
  });

  test('a head cut short asks for more instead of guessing', () {
    // Inside the second sidx: the first is whole, the moof not yet seen.
    final short = head(film.headEnd - 100);
    final need = CmafIndex.headBytes(short)!;
    expect(need, greaterThan(short.length));
    expect(CmafIndex.parse(short), isNull);
    // Reading what it asked for is enough.
    expect(CmafIndex.parse(head(need)), isNotNull);
  });

  test('a long film — an index of a few hundred KB — is read in two steps', () {
    final long = FakeCmaf.build(fragments: 4500, fragmentBytes: 1024);
    final first = Uint8List.sublistView(long.bytes, 0, 64 * 1024);
    final need = CmafIndex.headBytes(first)!;
    expect(need, greaterThan(64 * 1024));
    final idx = CmafIndex.parse(Uint8List.sublistView(long.bytes, 0, need))!;
    expect(idx.length, 4500);
    expect(idx.timesMs.last, 9000000); // two and a half hours
  });

  test('64-bit times (sidx version 1) and a late first frame', () {
    final v1 = FakeCmaf.build(version: 1, ept: 1024);
    final idx = CmafIndex.parse(Uint8List.sublistView(v1.bytes, 0, v1.headEnd + 16))!;
    expect(idx.starts, v1.fragmentStarts);
    // Times are counted from the first frame, as the player counts them.
    expect(idx.timesMs.first, 0);
    expect(idx.timesMs[5], 10000);
  });

  test('not a fragmented film: null, and the caller reopens as before', () {
    final b = BytesBuilder();
    void box(String kind, int len) {
      final h = ByteData(4)..setUint32(0, len + 8);
      b
        ..add(h.buffer.asUint8List())
        ..add(kind.codeUnits)
        ..add(List<int>.filled(len, 0));
    }

    box('ftyp', 16);
    box('moov', 3000);
    box('mdat', 70000);
    final faststart = b.toBytes();
    expect(CmafIndex.parse(faststart), isNull);
    expect(CmafIndex.headBytes(faststart), isNull);
    expect(CmafIndex.parse(Uint8List.fromList(List<int>.filled(4096, 0))), isNull);
    expect(CmafIndex.parse(Uint8List(0)), isNull);
  });

  group('rangeFor', () {
    final idx = CmafIndex.parse(head())!;

    test('from the fragment holding the moment, ten seconds on', () {
      final (from, to, filmLen) =
          idx.rangeFor(const Duration(seconds: 13), const Duration(seconds: 10), capBytes: 8 << 20)!;
      // 13 s is in the fragment from 12 s (index 6); 23 s in the one from
      // 22 s (index 11).
      expect(from, film.fragmentStarts[6]);
      expect(to, film.fragmentStarts[11] + film.fragmentSizes[11] - 1);
      expect(filmLen, const Duration(seconds: 12));
    });

    test('just past a boundary starts a fragment early: the keyframe is in it', () {
      final (from, _, _) =
          idx.rangeFor(const Duration(milliseconds: 12100), const Duration(seconds: 4), capBytes: 8 << 20)!;
      expect(from, film.fragmentStarts[5]);
    });

    test('never more than the cap — but always the fragment holding the moment', () {
      final (from, to, _) =
          idx.rangeFor(const Duration(seconds: 21), const Duration(seconds: 30), capBytes: 200 * 1024)!;
      expect(from, film.fragmentStarts[10]);
      expect(to - from + 1, 3 * 64 * 1024);
      final (f2, t2, _) =
          idx.rangeFor(const Duration(seconds: 21), const Duration(seconds: 30), capBytes: 1)!;
      expect((f2, t2 - f2 + 1), (film.fragmentStarts[10], 64 * 1024));
    });

    test('at the end of the film: what is left; past it: null', () {
      final (_, to, _) =
          idx.rangeFor(const Duration(seconds: 57), const Duration(seconds: 10), capBytes: 8 << 20)!;
      expect(to, film.bytes.length - 1);
      expect(idx.rangeFor(const Duration(seconds: 60), const Duration(seconds: 10), capBytes: 8 << 20), isNull);
    });

    test('the first moment of the film', () {
      final (from, _, _) = idx.rangeFor(Duration.zero, const Duration(seconds: 2), capBytes: 8 << 20)!;
      expect(from, film.fragmentStarts.first);
    });
  });
}
