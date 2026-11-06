/// Where things are in a sealed object (media seal v1, docs/MEDIA_ENCRYPTION.md).
///
/// The arithmetic only. Opening a segment is the platform's job
/// (`MediaSeal.kt`, Conscrypt's AES-GCM); this is what the stream proxy needs
/// to turn the player's byte range into one aligned range request and back.
///
/// The format is Google Tink's AES-GCM-HKDF streaming AEAD with a 64 KiB
/// ciphertext segment: a 40-byte header, then segments of 65536 bytes (the
/// first 65496, because the header shares its slot), each the plaintext plus a
/// 16-byte tag. Segment i >= 1 starts at sealed offset exactly i * 65536.
///
/// Offsets are `int`, which is 64-bit on every platform this app runs on: a
/// two-hour Original is past 4 GB.
library;

class MediaSealLayout {
  MediaSealLayout._();

  static const int segment = 65536;
  static const int tag = 16;
  static const int header = 40;
  static const int plainSegment = segment - tag; // 65520
  static const int firstPlain = segment - header - tag; // 65480

  static int segmentCount(int plain) {
    if (plain <= firstPlain) return 1;
    return 1 + (plain - firstPlain + plainSegment - 1) ~/ plainSegment;
  }

  static int sealedSize(int plain) => header + plain + tag * segmentCount(plain);

  /// The plaintext size of a sealed object of [sealed] bytes, or null when no
  /// plaintext seals to that size (a cut or padded object).
  static int? plainSize(int sealed) {
    if (sealed < header + tag) return null;
    final count = sealed ~/ segment + (sealed % segment == 0 ? 0 : 1);
    final n = sealed - header - tag * count;
    if (n < 0 || sealedSize(n) != sealed) return null;
    return n;
  }

  static int plainStart(int i) => i == 0 ? 0 : firstPlain + (i - 1) * plainSegment;

  static int sealedStart(int i) => i == 0 ? header : i * segment;

  static int segmentOf(int plainOffset) =>
      plainOffset < firstPlain ? 0 : 1 + (plainOffset - firstPlain) ~/ plainSegment;

  /// The sealed bytes `[start, end)` that hold plaintext `[first, last]`
  /// (inclusive, as an HTTP range is), and the segments in them.
  static SealedSpan spanFor(int first, int last, int plainTotal) {
    if (first < 0 || first > last || last >= (plainTotal > 0 ? plainTotal : 1)) {
      throw RangeError('range $first-$last outside $plainTotal');
    }
    final a = segmentOf(first);
    final b = segmentOf(last);
    final count = segmentCount(plainTotal);
    final end = b + 1 < count ? sealedStart(b + 1) : sealedSize(plainTotal);
    return SealedSpan(sealedStart(a), end, a, b);
  }
}

/// A run of whole segments: `[start, end)` in the sealed object, segments
/// [first]..[last].
class SealedSpan {
  const SealedSpan(this.start, this.end, this.first, this.last);

  final int start;
  final int end;
  final int first;
  final int last;

  /// Where plaintext byte [plainOffset] sits in the opened run.
  int skipFor(int plainOffset) => plainOffset - MediaSealLayout.plainStart(first);

  @override
  String toString() => 'SealedSpan($start-$end, segments $first..$last)';
}
