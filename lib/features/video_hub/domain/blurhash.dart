import 'dart:math' as math;
import 'dart:typed_data';

/// Decodes a blurhash — the thirty-character picture the runner makes for
/// every album item (tool/previews.py, migration 031).
///
/// ─── WHY IT IS HERE AND NOT A PACKAGE ───────────────────────────────────
///
/// It is forty lines of arithmetic from the published algorithm
/// (github.com/woltapp/blurhash), the mirror of the forty in the runner's
/// encoder, and it never changes. The two halves are tested against the SAME
/// vectors (tool/previews_test.py, test/blurhash_test.dart), which is the only
/// thing that keeps a frosted tile the colour of the photo behind it — a
/// slip on either side draws every tile wrong and throws nowhere.
///
/// Returns null for anything that is not a well-formed hash, so a bad row
/// draws as a plain tile instead of an exception in a grid.
class BlurHash {
  const BlurHash._();

  static const String _alphabet =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
      r'#$%*+,-.:;=?@[]^_{|}~';

  static int? _decode83(String s, int from, int to) {
    var value = 0;
    for (var i = from; i < to; i++) {
      final digit = _alphabet.indexOf(s[i]);
      if (digit < 0) return null;
      value = value * 83 + digit;
    }
    return value;
  }

  static double _srgbToLinear(int v) {
    final c = v / 255.0;
    return c <= 0.04045
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  static int _linearToSrgb(double v) {
    final c = v.clamp(0.0, 1.0);
    if (c <= 0.0031308) return (c * 12.92 * 255 + 0.5).toInt();
    return ((1.055 * math.pow(c, 1 / 2.4) - 0.055) * 255 + 0.5).toInt();
  }

  static double _signPow(double v, double exp) =>
      (v < 0 ? -1 : 1) * math.pow(v.abs(), exp).toDouble();

  /// True when [hash] has the shape of a blurhash: a length that matches the
  /// component count its first character declares, and only its alphabet.
  static bool isValid(String hash) {
    if (hash.length < 6) return false;
    final size = _decode83(hash, 0, 1);
    if (size == null) return false;
    final nx = size % 9 + 1;
    final ny = size ~/ 9 + 1;
    if (hash.length != 4 + 2 * nx * ny) return false;
    for (var i = 0; i < hash.length; i++) {
      if (!_alphabet.contains(hash[i])) return false;
    }
    return true;
  }

  /// RGBA pixels, row-major, [width] × [height], or null when [hash] is not a
  /// blurhash.
  static Uint8List? decode(String hash, int width, int height,
      {double punch = 1}) {
    if (width <= 0 || height <= 0 || hash.length < 6) return null;
    final size = _decode83(hash, 0, 1);
    if (size == null) return null;
    final nx = size % 9 + 1;
    final ny = size ~/ 9 + 1;
    if (hash.length != 4 + 2 * nx * ny) return null;
    final quant = _decode83(hash, 1, 2);
    if (quant == null) return null;
    final maxValue = (quant + 1) / 166.0;

    final colors = List<List<double>>.filled(nx * ny, const <double>[0, 0, 0]);
    final dc = _decode83(hash, 2, 6);
    if (dc == null) return null;
    colors[0] = <double>[
      _srgbToLinear(dc >> 16),
      _srgbToLinear((dc >> 8) & 255),
      _srgbToLinear(dc & 255),
    ];
    for (var i = 1; i < nx * ny; i++) {
      final ac = _decode83(hash, 4 + i * 2, 6 + i * 2);
      if (ac == null) return null;
      final qr = ac ~/ (19 * 19);
      final qg = (ac ~/ 19) % 19;
      final qb = ac % 19;
      colors[i] = <double>[
        _signPow((qr - 9) / 9.0, 2) * maxValue * punch,
        _signPow((qg - 9) / 9.0, 2) * maxValue * punch,
        _signPow((qb - 9) / 9.0, 2) * maxValue * punch,
      ];
    }

    final out = Uint8List(width * height * 4);
    // The cosines depend on one axis each; computing them once per row and
    // column rather than per pixel is the difference between a few thousand
    // and a few hundred thousand calls for a 32×32 tile.
    final cosX = List<List<double>>.generate(
        width,
        (x) => List<double>.generate(
            nx, (i) => math.cos(math.pi * x * i / width)));
    final cosY = List<List<double>>.generate(
        height,
        (y) => List<double>.generate(
            ny, (j) => math.cos(math.pi * y * j / height)));
    var p = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var r = 0.0, g = 0.0, b = 0.0;
        for (var j = 0; j < ny; j++) {
          for (var i = 0; i < nx; i++) {
            final basis = cosX[x][i] * cosY[y][j];
            final c = colors[i + j * nx];
            r += c[0] * basis;
            g += c[1] * basis;
            b += c[2] * basis;
          }
        }
        out[p++] = _linearToSrgb(r);
        out[p++] = _linearToSrgb(g);
        out[p++] = _linearToSrgb(b);
        out[p++] = 255;
      }
    }
    return out;
  }

  /// The decoded picture as a BMP file, which `Image.memory` draws directly.
  ///
  /// BMP because it is a header and the pixels — no compression to write, and
  /// one that every Flutter engine decodes. 32 × 32 is 4 KB in memory, made
  /// once per hash and kept (see [bmpFor]).
  static Uint8List? bmp(String hash, {int width = 32, int height = 32}) {
    final rgba = decode(hash, width, height);
    if (rgba == null) return null;
    const header = 14 + 40;
    final data = ByteData(header + rgba.length);
    // BITMAPFILEHEADER
    data.setUint8(0, 0x42);
    data.setUint8(1, 0x4D);
    data.setUint32(2, header + rgba.length, Endian.little);
    data.setUint32(10, header, Endian.little);
    // BITMAPINFOHEADER — a NEGATIVE height means top-down rows, so the pixels
    // go in exactly as decoded.
    data.setUint32(14, 40, Endian.little);
    data.setInt32(18, width, Endian.little);
    data.setInt32(22, -height, Endian.little);
    data.setUint16(26, 1, Endian.little);
    data.setUint16(28, 32, Endian.little);
    data.setUint32(30, 0, Endian.little); // BI_RGB
    data.setUint32(34, rgba.length, Endian.little);
    var o = header;
    for (var i = 0; i < rgba.length; i += 4) {
      // BMP is BGRA.
      data.setUint8(o++, rgba[i + 2]);
      data.setUint8(o++, rgba[i + 1]);
      data.setUint8(o++, rgba[i]);
      data.setUint8(o++, 255);
    }
    return data.buffer.asUint8List();
  }

  static final Map<String, Uint8List?> _cache = <String, Uint8List?>{};

  /// [bmp], made once per hash. An album of sixty is sixty small decodes the
  /// first time and none after; the cap keeps a long browse from growing it
  /// without bound.
  static Uint8List? bmpFor(String hash) {
    if (_cache.containsKey(hash)) return _cache[hash];
    if (_cache.length > 400) _cache.remove(_cache.keys.first);
    return _cache[hash] = bmp(hash);
  }
}
