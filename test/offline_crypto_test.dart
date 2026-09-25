// The trailer that tells a sealed film from a plain one.
//
// WHY THIS IS TESTED AND THE CIPHER IS NOT. The cipher is the platform's AES,
// reached through one call that is its own inverse; there is no arithmetic in it
// to get wrong. The trailer is where the arithmetic lives, and every way of
// getting it wrong is silent and costs somebody a film they spent an hour of
// mobile data on:
//
//   - A plain MP4 read as sealed is handed to a decryptor and drawn as noise.
//   - A sealed film read as plain is handed to libmpv and drawn as noise.
//   - A length off by thirty-two makes the shelf's own verification delete the
//     download that has just finished, or record a size that is not the film's.
//
// None of those throws. So the format is a pure function on bytes, and it is
// pinned here.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/api/offline_crypto.dart';

Uint8List iv16([int seed = 1]) =>
    Uint8List.fromList(<int>[for (var i = 0; i < 16; i++) (seed + i) & 0xFF]);

void main() {
  group('the trailer', () {
    test('is exactly thirty-two bytes, wherever it is written', () {
      // The number is arithmetic in four other files. If it ever changes, every
      // one of them is wrong and this is the test that says so.
      expect(OfflineCrypto.trailerLength, 32);
      expect(
        OfflineCrypto.composeTrailer(iv: iv16(), plainLength: 1),
        hasLength(32),
      );
    });

    test('round-trips the length and the IV', () {
      final iv = iv16(7);
      final t = OfflineCrypto.composeTrailer(iv: iv, plainLength: 123456789);
      final back = OfflineCrypto.readTrailer(t, 123456789 + 32);
      expect(back, isNotNull);
      expect(back!.plainLength, 123456789);
      expect(back.iv, iv);
    });

    test('carries a length no 32-bit number could hold', () {
      // A four-gigabyte master is past 2^32, and this audience's operator
      // uploads masters. A 32-bit field here would have silently wrapped.
      const huge = 5 * 1024 * 1024 * 1024; // 5 GiB
      final t = OfflineCrypto.composeTrailer(iv: iv16(), plainLength: huge);
      expect(OfflineCrypto.readTrailer(t, huge + 32)?.plainLength, huge);
    });

    test('a zero-length film is still a legal trailer', () {
      final t = OfflineCrypto.composeTrailer(iv: iv16(), plainLength: 0);
      expect(OfflineCrypto.readTrailer(t, 32)?.plainLength, 0);
    });

    test('refuses an IV that is not the block size', () {
      // Sixteen bytes is the counter block. A shorter one would be padded by
      // whatever happened to be next in the buffer, which is a keystream
      // nobody can reproduce.
      expect(
        () => OfflineCrypto.composeTrailer(
            iv: Uint8List(8), plainLength: 10),
        throwsArgumentError,
      );
      expect(
        () => OfflineCrypto.composeTrailer(
            iv: Uint8List(17), plainLength: 10),
        throwsArgumentError,
      );
    });

    test('refuses a negative length', () {
      expect(
        () => OfflineCrypto.composeTrailer(iv: iv16(), plainLength: -1),
        throwsArgumentError,
      );
    });
  });

  group('telling a sealed film from a plain one', () {
    test('a plain MP4 is not mistaken for a sealed film', () {
      // THE CASE THAT MATTERS MOST. Every download made before this feature
      // existed is a plain MP4 on somebody's phone, and the app does not get to
      // make people download their films again.
      final tail = Uint8List.fromList(
          <int>[for (var i = 0; i < 32; i++) (i * 7) & 0xFF]);
      expect(OfflineCrypto.readTrailer(tail, 4096), isNull);
    });

    test('the magic alone is not enough — the length has to agree', () {
      // The magic could occur by accident in the last thirty-two bytes of some
      // file somewhere. The magic PLUS a length that happens to equal this
      // file's own length minus thirty-two could not.
      final t = OfflineCrypto.composeTrailer(iv: iv16(), plainLength: 1000);
      expect(OfflineCrypto.readTrailer(t, 1000 + 32), isNotNull);
      expect(OfflineCrypto.readTrailer(t, 1000 + 31), isNull);
      expect(OfflineCrypto.readTrailer(t, 1000 + 33), isNull);
      expect(OfflineCrypto.readTrailer(t, 999), isNull);
    });

    test('a corrupted magic byte reads as plain, not as damage', () {
      final t = OfflineCrypto.composeTrailer(iv: iv16(), plainLength: 64);
      for (var i = 0; i < 4; i++) {
        final broken = Uint8List.fromList(t);
        broken[i] = broken[i] ^ 0xFF;
        expect(OfflineCrypto.readTrailer(broken, 96), isNull,
            reason: 'byte $i of the magic must be load-bearing');
      }
    });

    test('a version this build does not know is refused', () {
      // A FUTURE FORMAT IS NOT A PLAIN FILE, but refusing is still the right
      // answer: the row saying the film is sealed is what turns this into
      // "damaged, download it again" rather than into noise on screen.
      final t = OfflineCrypto.composeTrailer(iv: iv16(), plainLength: 64);
      final future = Uint8List.fromList(t);
      future[4] = 9;
      expect(OfflineCrypto.readTrailer(future, 96), isNull);
    });

    test('a tail of the wrong size is refused rather than indexed into', () {
      final t = OfflineCrypto.composeTrailer(iv: iv16(), plainLength: 64);
      expect(OfflineCrypto.readTrailer(t.sublist(0, 31), 96), isNull);
      expect(OfflineCrypto.readTrailer(Uint8List(0), 0), isNull);
    });
  });

  group('the length a file should be', () {
    test('a sealed film is its object plus the trailer', () {
      expect(OfflineCrypto.fileLengthFor(1000, sealed: true), 1032);
      expect(OfflineCrypto.fileLengthFor(1000, sealed: false), 1000);
    });

    test('`bytes` on the shelf stays the length of the ORIGINAL', () {
      // The invariant the whole download feature rests on: what arrives is the
      // object that was uploaded, at full quality, and what the shelf shows is
      // that object's size — not the size of the container it is kept in.
      final t = OfflineCrypto.composeTrailer(iv: iv16(), plainLength: 2048);
      final seal = OfflineCrypto.readTrailer(t, 2048 + 32)!;
      expect(seal.plainLength,
          OfflineCrypto.fileLengthFor(2048, sealed: true) - 32);
    });
  });

  group('the IV as the cipher is asked for it', () {
    test('base64 with no padding surprises, and it round-trips', () {
      final seal = OfflineCrypto.readTrailer(
        OfflineCrypto.composeTrailer(iv: iv16(200), plainLength: 5),
        37,
      )!;
      // The platform decodes this string back to the same sixteen bytes; a
      // mismatch here is a keystream nobody can reproduce, so the encoding is
      // pinned rather than assumed.
      expect(seal.ivBase64, isA<String>());
      expect(seal.ivBase64.length, 24); // 16 bytes, padded base64
      expect(seal.iv, iv16(200));
    });
  });
}
