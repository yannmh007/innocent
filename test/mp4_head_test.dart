// Whether a film can be watched while it is still downloading.
//
// WHY THIS IS TESTED. Its answer is a button, and both ways of being wrong are
// silent. `ready` on a film whose index is at the end opens a black screen with
// a spinner that never resolves, on the screen whose whole job is to be
// reassuring. `indexAtEnd` on a film that is fine hides a feature nobody will
// then find. Neither throws, and a mis-walked box list returns a confident,
// plausible, wrong answer — which is the same reason the console's own box
// walker is tested in tool/js/probe_boxes_test.mjs.
//
// The walk is a pure function on bytes, so every case below is exact.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/mp4_head.dart';

/// A top-level box with [payload] bytes of contents.
Uint8List box(String type, int payload) {
  final out = Uint8List(8 + payload);
  ByteData.sublistView(out).setUint32(0, 8 + payload, Endian.big);
  out.setRange(4, 8, type.codeUnits);
  return out;
}

/// A box whose declared size is written by hand — for the illegal ones.
Uint8List rawBox(String type, int declared, {int payload = 0}) {
  final out = Uint8List(8 + payload);
  ByteData.sublistView(out).setUint32(0, declared, Endian.big);
  out.setRange(4, 8, type.codeUnits);
  return out;
}

/// A 64-bit box: size 1, then the real size after the type.
Uint8List box64(String type, int total) {
  final out = Uint8List(total < 16 ? 16 : total);
  final v = ByteData.sublistView(out);
  v.setUint32(0, 1, Endian.big);
  out.setRange(4, 8, type.codeUnits);
  v.setUint64(8, total, Endian.big);
  return out;
}

Uint8List join(List<Uint8List> parts) {
  final out = Uint8List(parts.fold<int>(0, (a, b) => a + b.length));
  var at = 0;
  for (final p in parts) {
    out.setRange(at, at + p.length, p);
    at += p.length;
  }
  return out;
}

void main() {
  group('the index is at the front — the case this feature exists for', () {
    test('ready once the index and a few seconds of frames have arrived', () {
      final head = join(<Uint8List>[box('ftyp', 16), box('moov', 400)]);
      // moov ends at 24 + 408 = 432.
      final v = assessMp4Head(head,
          onDisk: 432 + 4 * 1024 * 1024, total: 100 * 1024 * 1024);
      expect(v.state, ProgressiveState.ready);
      expect(v.moovEnd, 432);
      expect(v.needed, 432 + 4 * 1024 * 1024);
    });

    test('waiting while the index is still only partly there', () {
      // THE CASE THAT LOOKS READY AND IS NOT. The box header says how long the
      // index is, and it says so in the first eight bytes — so a walk that
      // answered on the header alone would call this ready and hand the player
      // half an index.
      final head = join(<Uint8List>[box('ftyp', 16), box('moov', 400)]);
      final v =
          assessMp4Head(head, onDisk: 200, total: 100 * 1024 * 1024);
      expect(v.state, ProgressiveState.waiting);
      expect(v.moovEnd, 432);
    });

    test('waiting while the frames after the index have not arrived', () {
      final head = join(<Uint8List>[box('ftyp', 16), box('moov', 400)]);
      final v = assessMp4Head(head,
          onDisk: 500, total: 100 * 1024 * 1024, margin: 1024 * 1024);
      expect(v.state, ProgressiveState.waiting);
      expect(v.needed, 432 + 1024 * 1024);
    });

    test('a short film needs only its own length, not index plus margin', () {
      // A film smaller than the margin would otherwise be unplayable until it
      // was more than complete, which is a number of bytes that cannot arrive.
      final head = join(<Uint8List>[box('ftyp', 16), box('moov', 400)]);
      final v = assessMp4Head(head, onDisk: 1000, total: 1000);
      expect(v.needed, 1000);
      expect(v.state, ProgressiveState.ready);
    });

    test('boxes before the index are walked over, not stumbled on', () {
      final head = join(<Uint8List>[
        box('ftyp', 16),
        box('free', 2048),
        box('uuid', 64),
        box('moov', 300),
      ]);
      final end = 24 + 2056 + 72 + 308;
      final v =
          assessMp4Head(head, onDisk: end + 8 * 1024 * 1024, total: 1 << 30);
      expect(v.state, ProgressiveState.ready);
      expect(v.moovEnd, end);
    });

    test('a 64-bit box is skipped by its real size, not its 32-bit field', () {
      // Reading the size-1 marker as a size walks the cursor to byte 1 and
      // answers about whatever happens to be there.
      final big = box64('free', 4096);
      final head = join(<Uint8List>[box('ftyp', 16), big, box('moov', 100)]);
      final v = assessMp4Head(head, onDisk: 1 << 24, total: 1 << 30);
      expect(v.state, ProgressiveState.ready);
      expect(v.moovEnd, 24 + 4096 + 108);
    });
  });

  group('the index is at the end — nothing to do but wait', () {
    test('frames before the index', () {
      final head = join(<Uint8List>[box('ftyp', 16), box('mdat', 4096)]);
      expect(assessMp4Head(head, onDisk: 1 << 24, total: 1 << 30).state,
          ProgressiveState.indexAtEnd);
    });

    test('frames that run to the end of the file', () {
      // A size of zero means "to EOF", which is legal and is what some encoders
      // write. There is no index before it, so there is no index until the end.
      final head = join(<Uint8List>[box('ftyp', 16), rawBox('mdat', 0)]);
      expect(assessMp4Head(head, onDisk: 1 << 24, total: 1 << 30).state,
          ProgressiveState.indexAtEnd);
    });

    test('an index that runs to the end of the file is an index at the end',
        () {
      final head = join(<Uint8List>[box('ftyp', 16), rawBox('moov', 0)]);
      expect(assessMp4Head(head, onDisk: 1 << 24, total: 1 << 30).state,
          ProgressiveState.indexAtEnd);
    });
  });

  group('malformed, and refused rather than guessed at', () {
    // REFUSING IS THE CHEAP MISTAKE. A film this walk does not understand is
    // still perfectly watchable once it has finished downloading; a film it
    // guesses about is a black screen somebody has to back out of.

    test('a box shorter than its own header', () {
      final head = join(<Uint8List>[box('ftyp', 16), rawBox('junk', 4)]);
      expect(assessMp4Head(head, onDisk: 1 << 24, total: 1 << 30).state,
          ProgressiveState.indexAtEnd);
    });

    test('a 64-bit size above 2^63, which Dart hands back as negative', () {
      // AND THIS IS NOT A THEORETICAL CASE TO BE TIDY ABOUT. A negative size
      // walks the cursor BACKWARDS, which is not a wrong answer but an endless
      // loop — inside a list's tap handler.
      final bad = Uint8List(16);
      ByteData.sublistView(bad).setUint32(0, 1, Endian.big);
      bad.setRange(4, 8, 'free'.codeUnits);
      for (var i = 8; i < 16; i++) {
        bad[i] = 0xFF;
      }
      final head = join(<Uint8List>[box('ftyp', 16), bad]);
      expect(assessMp4Head(head, onDisk: 1 << 24, total: 1 << 30).state,
          ProgressiveState.indexAtEnd);
    });

    test('a 64-bit size smaller than its own header', () {
      final head = join(<Uint8List>[box('ftyp', 16), box64('free', 8)]);
      expect(assessMp4Head(head, onDisk: 1 << 24, total: 1 << 30).state,
          ProgressiveState.indexAtEnd);
    });
  });

  group('not enough to tell yet', () {
    test('nothing at all', () {
      expect(assessMp4Head(Uint8List(0), onDisk: 0, total: 1000).state,
          ProgressiveState.waiting);
    });

    test('a header that is cut in half', () {
      expect(
          assessMp4Head(Uint8List.fromList(<int>[0, 0, 0, 24, 102]),
                  onDisk: 5, total: 1000)
              .state,
          ProgressiveState.waiting);
    });

    test('boxes, but neither of the two that decide it', () {
      // The ordinary state in the first seconds of a download.
      final head = join(<Uint8List>[box('ftyp', 16), box('free', 32)]);
      expect(assessMp4Head(head, onDisk: 64, total: 1 << 30).state,
          ProgressiveState.waiting);
    });

    test('a 64-bit box whose real size has not arrived', () {
      final cut = box64('free', 4096).sublist(0, 12);
      final head = join(<Uint8List>[box('ftyp', 16), cut]);
      expect(assessMp4Head(head, onDisk: 36, total: 1 << 30).state,
          ProgressiveState.waiting);
    });
  });
}
