// A film laid out as the streaming ladder writes it (tool/transcode.sh):
// ftyp, a small moov, one sidx per track, then a moof+mdat per fragment.
// The boxes are real enough for the index to be read; the media is noise.
import 'dart:math';
import 'dart:typed_data';

class FakeCmaf {
  FakeCmaf._(this.bytes, this.fragmentStarts, this.fragmentSizes, this.headEnd);

  final Uint8List bytes;
  final List<int> fragmentStarts;
  final List<int> fragmentSizes;

  /// Where the first moof begins.
  final int headEnd;

  /// [fragments] fragments of [seconds] each, [fragmentBytes] bytes each
  /// (moof and mdat together); [version] 1 writes the sidx with 64-bit times.
  static FakeCmaf build({
    int fragments = 30,
    int fragmentBytes = 64 * 1024,
    double seconds = 2,
    int timescale = 15360,
    int ept = 0,
    int version = 0,
    int seed = 7,
  }) {
    final out = BytesBuilder();
    void box(String kind, List<int> body) {
      final h = ByteData(4)..setUint32(0, body.length + 8);
      out
        ..add(h.buffer.asUint8List())
        ..add(kind.codeUnits)
        ..add(body);
    }

    box('ftyp', 'iso6avc1cmfc'.codeUnits);
    box('moov', List<int>.filled(1200, 0));
    final duration = (seconds * timescale).round();
    List<int> sidx(int trackId, int scale, int firstOffset) {
      final b = BytesBuilder();
      final w = ByteData(32);
      w.setUint32(0, version << 24);
      w.setUint32(4, trackId);
      w.setUint32(8, scale);
      b.add(w.buffer.asUint8List(0, 12));
      if (version == 0) {
        final t = ByteData(8)
          ..setUint32(0, ept)
          ..setUint32(4, firstOffset);
        b.add(t.buffer.asUint8List());
      } else {
        final t = ByteData(16)
          ..setUint64(0, ept)
          ..setUint64(8, firstOffset);
        b.add(t.buffer.asUint8List());
      }
      final c = ByteData(4)..setUint16(2, fragments);
      b.add(c.buffer.asUint8List());
      for (var i = 0; i < fragments; i++) {
        final r = ByteData(12)
          ..setUint32(0, fragmentBytes)
          ..setUint32(4, (duration * scale / timescale).round())
          ..setUint32(8, 0x90000000);
        b.add(r.buffer.asUint8List());
      }
      return b.toBytes();
    }

    // The picture's sidx points past the sound's, as ffmpeg's does.
    final sound = sidx(2, 48000, 0);
    box('sidx', sidx(1, timescale, sound.length + 8));
    box('sidx', sound);
    final headEnd = out.length;
    final r = Random(seed);
    final starts = <int>[];
    for (var i = 0; i < fragments; i++) {
      starts.add(out.length);
      box('moof', List<int>.generate(200, (_) => r.nextInt(256)));
      box('mdat', List<int>.generate(fragmentBytes - 216, (_) => r.nextInt(256)));
    }
    return FakeCmaf._(out.toBytes(), starts, List<int>.filled(fragments, fragmentBytes), headEnd);
  }
}
