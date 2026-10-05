import 'package:flutter/widgets.dart';

import '../../../core/localization/app_strings.dart';

/// MX Player's screen modes, in the order its one button cycles them:
/// Fit to screen → Stretch → Crop → 100% → Custom
/// (docs/player_playback_modes.md).
///
/// Every mode but Stretch keeps the film's shape. Crop is a ZOOM until the
/// black bars are gone — nothing is cut away: the picture past the screen's
/// edges is still there and a two-finger drag brings it into view. 100% is
/// one video pixel on one screen pixel; Custom is the user's own pinch zoom
/// and pan, which any pinch switches to. The arithmetic is in
/// video_geometry.dart.
enum AspectRatioMode {
  fit, // whole frame, letterboxed
  stretch, // fills the screen, shape ignored
  crop, // zoomed to fill, shape kept, the overflow pannable
  original, // 100 %: one video pixel per screen pixel
  custom; // the user's pinch zoom and pan

  /// English name, for logs and tooltips without a context.
  String get label {
    switch (this) {
      case AspectRatioMode.fit:
        return 'Fit to screen';
      case AspectRatioMode.stretch:
        return 'Stretch';
      case AspectRatioMode.crop:
        return 'Crop';
      case AspectRatioMode.original:
        return '100%';
      case AspectRatioMode.custom:
        return 'Custom';
    }
  }

  /// The name on the button's tooltip and over the video, in the app's
  /// language.
  String labelIn(AppStrings s) {
    switch (this) {
      case AspectRatioMode.fit:
        return s.zmFit;
      case AspectRatioMode.stretch:
        return s.zmStretch;
      case AspectRatioMode.crop:
        return s.zmCrop;
      case AspectRatioMode.original:
        return s.zmOriginal;
      case AspectRatioMode.custom:
        return s.zmCustom;
    }
  }

  /// How the texture is laid out before the mode's zoom is applied: the
  /// whole frame for every mode but Stretch, which fills the player.
  BoxFit get boxFit =>
      this == AspectRatioMode.stretch ? BoxFit.fill : BoxFit.contain;

  /// The next mode on the button (MX's order, wrapping round).
  AspectRatioMode get next {
    const values = AspectRatioMode.values;
    return values[(index + 1) % values.length];
  }
}

/// Phase 45 (audit refined): MX Player V3's EXPLICIT aspect ratio
/// override (separate from the 4-mode behavior above). MX Player has
/// 12 options matching the decompiled `aspect_ratios_landscape` array.
/// This forces libmpv to render at the given aspect ratio regardless
/// of the file's embedded SAR/DAR metadata — useful for content with
/// wrong or missing aspect info (common with older Asian cinema).
///
/// `defaultAuto` means "use the file's embedded aspect ratio"
/// (libmpv default). All other values map to a fixed numeric ratio
/// passed to `video-aspect-override` (e.g. "16:9" → 16/9 = 1.777).
enum AspectRatioOverride {
  defaultAuto('Default', null),
  r1x1('1:1', 1.0),
  r4x3('4:3', 4.0 / 3.0),
  r16x9('16:9', 16.0 / 9.0),
  r16x10('16:10', 16.0 / 10.0),
  r21x9('21:9 (2.33:1)', 21.0 / 9.0),
  r64x27('64:27 (2.37:1)', 64.0 / 27.0),
  r221('2.21:1', 2.21),
  r235('2.35:1', 2.35),
  r239('2.39:1', 2.39),
  r5x4('5:4', 5.0 / 4.0),
  custom('Custom', null);

  /// Human-readable label (matches MX Player V3 exact wording)
  final String label;

  /// Numeric aspect ratio to send to libmpv's `video-aspect-override`.
  /// `null` = let libmpv use the file's intrinsic aspect (for
  /// `defaultAuto` and `custom`).
  final double? value;

  const AspectRatioOverride(this.label, this.value);

  /// Map a stored string (from ExtraSettings) back to enum.
  static AspectRatioOverride fromString(String? s) {
    if (s == null || s.isEmpty) return AspectRatioOverride.defaultAuto;
    for (final v in AspectRatioOverride.values) {
      if (v.name == s) return v;
    }
    return AspectRatioOverride.defaultAuto;
  }
}
