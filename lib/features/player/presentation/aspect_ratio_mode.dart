import 'package:flutter/widgets.dart';

/// Aspect ratio modes for video display.
///
/// The zoom-style modes (fit / crop) keep the video's aspect ratio and use
/// libmpv `panscan` to SCALE toward filling the screen — a smooth zoom the
/// user can further adjust by pinching — rather than hard-cropping the
/// texture. Only [stretch] distorts, and [original] shows true pixel size.
enum AspectRatioMode {
  fit,        // letterbox - keep ratio, black bars (panscan 0.0)
  crop,       // zoom to fill - keep ratio (panscan 1.0), NOT a hard crop
  stretch,    // fill screen - ignore ratio, distorted
  original;   // 100% original size

  String get label {
    switch (this) {
      case AspectRatioMode.fit:
        return 'Fit';
      case AspectRatioMode.crop:
        return 'Zoom';
      case AspectRatioMode.stretch:
        return 'Stretch';
      case AspectRatioMode.original:
        return '100%';
    }
  }

  BoxFit get boxFit {
    switch (this) {
      // fit + crop both render the FULL frame (contain) in the Flutter
      // layer; the "fill" look for crop comes from libmpv panscan, so we
      // never hard-crop the texture and the zoom stays smooth + adjustable.
      case AspectRatioMode.fit:
        return BoxFit.contain;
      case AspectRatioMode.crop:
        return BoxFit.contain;
      case AspectRatioMode.stretch:
        return BoxFit.fill;
      case AspectRatioMode.original:
        return BoxFit.none;
    }
  }

  /// libmpv panscan (0.0–1.0) for this mode: 1.0 zooms the video to fill the
  /// screen keeping aspect (the MX-Player "Fit to Screen" feel), 0.0 fits.
  double get panscan {
    switch (this) {
      case AspectRatioMode.crop:
        return 1.0; // zoom to fill
      case AspectRatioMode.fit:
      case AspectRatioMode.stretch:
      case AspectRatioMode.original:
        return 0.0;
    }
  }

  /// Cycle to next aspect ratio mode
  AspectRatioMode get next {
    const values = AspectRatioMode.values;
    final nextIndex = (index + 1) % values.length;
    return values[nextIndex];
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
