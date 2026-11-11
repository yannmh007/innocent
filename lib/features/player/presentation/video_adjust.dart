import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The picture adjustments of the player's Display Settings sheet:
/// brightness, contrast, saturation and hue, each from -1 to 1, 0 untouched.
///
/// THEY USED TO DO NOTHING. The sheet's four sliders moved numbers held in
/// the sheet itself and nothing ever read them: the picture never changed,
/// and the numbers were back at 0 the next time the sheet opened. They now
/// colour the picture the way Night mode does — a colour matrix over the
/// video widget, so it works the same on libmpv and on ExoPlayer — and they
/// last as long as the player is open.
@immutable
class VideoAdjust {
  const VideoAdjust({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.hue = 0,
  });

  final double brightness;
  final double contrast;
  final double saturation;
  final double hue;

  /// Nothing to draw: the picture as it comes.
  bool get isNeutral =>
      brightness == 0 && contrast == 0 && saturation == 0 && hue == 0;

  VideoAdjust copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? hue,
  }) =>
      VideoAdjust(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        hue: hue ?? this.hue,
      );

  /// The 4 × 5 colour matrix (rows R, G, B, A; offsets in 0–255) for
  /// `ColorFilter.matrix`: hue, then saturation, then contrast, then
  /// brightness.
  ///
  ///  * brightness: shifts every channel by up to ±40 % of full scale;
  ///  * contrast: scales about mid-grey, from flat grey (-1) to double (1);
  ///  * saturation: from grey (-1) to twice as vivid (1), keeping each
  ///    pixel's luminance (Rec. 709 weights);
  ///  * hue: turns the colour wheel by up to ±180°.
  List<double> get matrix {
    var m = _identity;
    if (hue != 0) m = _multiply(_hueMatrix(hue * math.pi), m);
    if (saturation != 0) m = _multiply(_saturationMatrix(1 + saturation), m);
    if (contrast != 0) m = _multiply(_contrastMatrix(1 + contrast), m);
    if (brightness != 0) m = _multiply(_offsetMatrix(brightness * 0.4 * 255), m);
    return m;
  }

  @override
  bool operator ==(Object other) =>
      other is VideoAdjust &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.hue == hue;

  @override
  int get hashCode => Object.hash(brightness, contrast, saturation, hue);
}

/// The picture adjustments for the player that is open. Released with it,
/// so the next film starts untouched.
final videoAdjustProvider =
    StateProvider.autoDispose<VideoAdjust>((ref) => const VideoAdjust());

/// Two colour matrices as one: [a] applied after [b].
List<double> composeColorMatrices(List<double> a, List<double> b) =>
    _multiply(a, b);

const List<double> _identity = <double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// [a] after [b], both 4 × 5 colour matrices (the fifth column an offset).
List<double> _multiply(List<double> a, List<double> b) {
  final out = List<double>.filled(20, 0);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 5; c++) {
      var v = 0.0;
      for (var k = 0; k < 4; k++) {
        v += a[r * 5 + k] * b[k * 5 + c];
      }
      if (c == 4) v += a[r * 5 + 4];
      out[r * 5 + c] = v;
    }
  }
  return out;
}

List<double> _offsetMatrix(double o) => <double>[
      1, 0, 0, 0, o, //
      0, 1, 0, 0, o, //
      0, 0, 1, 0, o, //
      0, 0, 0, 1, 0, //
    ];

List<double> _contrastMatrix(double k) {
  final o = 128 * (1 - k);
  return <double>[
    k, 0, 0, 0, o, //
    0, k, 0, 0, o, //
    0, 0, k, 0, o, //
    0, 0, 0, 1, 0, //
  ];
}

const double _lr = 0.2126, _lg = 0.7152, _lb = 0.0722;

List<double> _saturationMatrix(double s) {
  final i = 1 - s;
  return <double>[
    _lr * i + s, _lg * i, _lb * i, 0, 0, //
    _lr * i, _lg * i + s, _lb * i, 0, 0, //
    _lr * i, _lg * i, _lb * i + s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

/// The usual luminance-preserving hue rotation by [a] radians.
List<double> _hueMatrix(double a) {
  final c = math.cos(a), s = math.sin(a);
  return <double>[
    _lr + c * (1 - _lr) + s * -_lr, //
    _lg + c * -_lg + s * -_lg, //
    _lb + c * -_lb + s * (1 - _lb), //
    0, 0, //
    _lr + c * -_lr + s * 0.143, //
    _lg + c * (1 - _lg) + s * 0.140, //
    _lb + c * -_lb + s * -0.283, //
    0, 0, //
    _lr + c * -_lr + s * -(1 - _lr), //
    _lg + c * -_lg + s * _lg, //
    _lb + c * (1 - _lb) + s * _lb, //
    0, 0, //
    0, 0, 0, 1, 0, //
  ];
}
