import 'dart:typed_data';

/// ITP1 packs for tests (docs/trickplay_plan.md; tool/trickplay.py is the
/// reference). Made-up pictures only: the repository is public, and no
/// film's picture goes in it.

/// A stand-in picture: SOI + APP0 marker, [n] bytes of [fill], EOI.
Uint8List fakeJpeg(int fill, int n) =>
    Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, ...List<int>.filled(n, fill & 0xFF), 0xFF, 0xD9]);

/// ITP1 bytes for [pictures], as tool/trickplay.py's `pack` lays them out.
Uint8List buildPack(List<Uint8List> pictures,
    {int intervalMs = 4000, int width = 320, int height = 180, int codec = 1, int version = 1}) {
  final n = pictures.length;
  final headerLen = 24 + 4 * (n + 1);
  final total = headerLen + pictures.fold<int>(0, (a, p) => a + p.length);
  final out = Uint8List(total);
  final b = ByteData.sublistView(out);
  out.setAll(0, 'ITP1'.codeUnits);
  b.setUint16(4, version);
  b.setUint16(6, codec);
  b.setUint32(8, intervalMs);
  b.setUint16(12, width);
  b.setUint16(14, height);
  b.setUint32(16, n);
  b.setUint32(20, headerLen);
  var at = headerLen;
  for (var i = 0; i < n; i++) {
    b.setUint32(24 + 4 * i, at);
    out.setAll(at, pictures[i]);
    at += pictures[i].length;
  }
  b.setUint32(24 + 4 * n, at);
  return out;
}
