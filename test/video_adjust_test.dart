// The Display Settings sheet's picture adjustments
// (lib/features/player/presentation/video_adjust.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/video_adjust.dart';

/// [m] applied to one pixel (0–255 per channel, alpha 255).
List<double> _apply(List<double> m, double r, double g, double b) => [
      for (var row = 0; row < 3; row++)
        m[row * 5] * r +
            m[row * 5 + 1] * g +
            m[row * 5 + 2] * b +
            m[row * 5 + 3] * 255 +
            m[row * 5 + 4],
    ];

void main() {
  test('untouched is the identity, and draws nothing', () {
    const a = VideoAdjust();
    expect(a.isNeutral, isTrue);
    expect(_apply(a.matrix, 10, 200, 90), [10, 200, 90]);
  });

  test('brightness lifts every channel alike', () {
    final p = _apply(const VideoAdjust(brightness: 0.5).matrix, 100, 100, 100);
    for (final c in p) {
      expect(c, closeTo(151, 0.01));
    }
  });

  test('contrast pivots on mid-grey', () {
    final m = const VideoAdjust(contrast: 1).matrix;
    expect(_apply(m, 128, 128, 128), [128, 128, 128]);
    expect(_apply(m, 160, 160, 160)[0], closeTo(192, 0.01));
  });

  test('no saturation is grey, at the same luminance', () {
    final p = _apply(const VideoAdjust(saturation: -1).matrix, 255, 0, 0);
    expect(p[0], closeTo(p[1], 0.001));
    expect(p[1], closeTo(p[2], 0.001));
    expect(p[0], closeTo(255 * 0.2126, 0.01));
  });

  test('a hue turn keeps grey grey and changes a colour', () {
    final m = const VideoAdjust(hue: 0.5).matrix;
    final grey = _apply(m, 90, 90, 90);
    for (final c in grey) {
      expect(c, closeTo(90, 0.001));
    }
    final red = _apply(m, 255, 0, 0);
    expect(red[0], lessThan(200));
  });

  test('composing with night mode is the same as filtering twice', () {
    const night = <double>[
      1, 0, 0, 0, 0, //
      0, 0.4, 0, 0, 0, //
      0, 0, 0.2, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
    final adjust = const VideoAdjust(brightness: 0.2, saturation: 0.3).matrix;
    final once = _apply(composeColorMatrices(night, adjust), 40, 120, 200);
    final first = _apply(adjust, 40, 120, 200);
    final twice = _apply(night, first[0], first[1], first[2]);
    for (var i = 0; i < 3; i++) {
      expect(once[i], closeTo(twice[i], 0.001));
    }
  });
}
