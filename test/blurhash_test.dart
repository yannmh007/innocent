// The app's blurhash decoder against the vectors the runner's encoder is
// pinned to (tool/previews_test.py). The expected pixels came from the
// reference `blurhash` package's decoder; a slip here draws every data-saver
// tile the wrong colour and throws nowhere.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/blurhash.dart';

void main() {
  // 4 × 3 decodes, row by row, (r, g, b).
  const grad = 'LyI5ej3AfQxtz4NKfQnSeXf7fQf7';
  const gradPixels = <List<int>>[
    [90, 0, 160], [78, 0, 140], [179, 0, 140], [234, 0, 140],
    [76, 151, 151], [64, 123, 130], [168, 123, 130], [223, 123, 130],
    [30, 226, 131], [5, 198, 109], [144, 198, 109], [197, 198, 109],
  ];
  const portrait = 'TyI5ej3AfQz4NKfQeXf7fQ%eOWfQ';
  const portraitPixels = <List<int>>[
    [64, 95, 166], [124, 90, 163], [198, 75, 156], [247, 55, 148],
    [0, 76, 121], [61, 70, 117], [144, 53, 109], [190, 26, 99],
    [0, 237, 141], [93, 232, 138], [168, 222, 130], [215, 211, 122],
  ];

  void matches(String hash, List<List<int>> want) {
    final px = BlurHash.decode(hash, 4, 3)!;
    expect(px.length, 4 * 3 * 4);
    for (var i = 0; i < want.length; i++) {
      for (var c = 0; c < 3; c++) {
        expect((px[i * 4 + c] - want[i][c]).abs(), lessThanOrEqualTo(2),
            reason: 'pixel $i channel $c: ${px[i * 4 + c]} vs ${want[i][c]}');
      }
      expect(px[i * 4 + 3], 255);
    }
  }

  test('a landscape hash decodes to the reference pixels', () {
    matches(grad, gradPixels);
  });

  test('a portrait (3 × 4 component) hash decodes to the reference pixels', () {
    matches(portrait, portraitPixels);
  });

  test('a flat colour decodes as the reference does, AC terms and all', () {
    // Blurhash's basis is half-cosines, whose sums over a small sample are not
    // zero, so even a flat image carries AC terms — the reference decoder
    // gives exactly these, and so must this one.
    final px = BlurHash.decode('LVM_Ai]VfQ]V||sofQsofQfQfQfQ', 2, 2)!;
    const want = <List<int>>[
      [255, 57, 120], [227, 49, 105], [241, 45, 106], [200, 40, 90],
    ];
    for (var i = 0; i < 4; i++) {
      for (var c = 0; c < 3; c++) {
        expect((px[i * 4 + c] - want[i][c]).abs(), lessThanOrEqualTo(2));
      }
    }
  });

  test('anything that is not a hash is null, never an exception', () {
    expect(BlurHash.decode('', 4, 4), isNull);
    expect(BlurHash.decode('short', 4, 4), isNull);
    // Declares 4 × 3 components but is two characters short.
    expect(BlurHash.decode(grad.substring(0, grad.length - 2), 4, 4), isNull);
    // A character outside the alphabet.
    expect(BlurHash.decode('LyI5ej3AfQxtz4NKfQnSeXf7fQf"', 4, 4), isNull);
    expect(BlurHash.isValid(grad), isTrue);
    expect(BlurHash.isValid('LyI5'), isFalse);
  });

  test('the BMP is a top-down 32-bit image of the decoded pixels', () {
    final bmp = BlurHash.bmp(grad, width: 4, height: 3)!;
    expect(bmp.length, 54 + 4 * 3 * 4);
    expect(String.fromCharCodes(bmp.sublist(0, 2)), 'BM');
    // First pixel, stored BGRA.
    expect((bmp[54 + 2] - 90).abs(), lessThanOrEqualTo(2));
    expect(bmp[54 + 1], lessThanOrEqualTo(2));
    expect((bmp[54] - 160).abs(), lessThanOrEqualTo(2));
    expect(identical(BlurHash.bmpFor(grad), BlurHash.bmpFor(grad)), isTrue);
  });
}
