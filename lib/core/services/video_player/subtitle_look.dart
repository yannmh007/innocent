import 'dart:ui' show Color;

/// How the subtitle should look, in libmpv's own terms.
///
/// WHY THIS EXISTS. media_kit starts libmpv with `sub-visibility=no` unless
/// libass is switched on (it is not here), and draws the subtitle text
/// itself, in Flutter, in a fixed style. So every `sub-*` property this app
/// sets — size, colour, outline, shadow, background, position, scale — was
/// accepted by libmpv and then never drawn: the Subtitle settings and the
/// subtitle gestures changed nothing on screen. The player now draws the
/// subtitle itself (player_subtitles.dart) from this record, which
/// [MediaKitPlayerService] keeps in step with every `sub-*` property it
/// sets, so the existing settings code works unchanged.
///
/// Values are as set: size, outline, shadow and margin in the app's subtitle
/// units (dp on a phone — see subtitle_band.dart), position in percent of
/// the picture's height from its top (100 = bottom).
class SubtitleLook {
  const SubtitleLook({
    this.fontSize = 18,
    this.scale = 1.0,
    this.position = 100,
    this.marginY = 14,
    this.color = const Color(0xFFFFFFFF),
    this.borderColor = const Color(0xFF000000),
    this.borderSize = 1.5,
    this.shadowColor = const Color(0x80000000),
    this.shadowOffset = 0,
    this.backColor = const Color(0x00000000),
    this.font,
    this.bold = false,
  });

  final double fontSize;
  final double scale;
  final double position;
  final double marginY;
  final Color color;
  final Color borderColor;
  final double borderSize;
  final Color shadowColor;
  final double shadowOffset;
  final Color backColor;

  /// A font family Flutter can use, or null for the system's (which also
  /// carries Myanmar and every other script the phone has).
  final String? font;
  final bool bold;

  /// This look with libmpv property [key] set to [value]; unchanged when
  /// the key is not about the look or the value does not parse.
  SubtitleLook apply(String key, String value) {
    double? n() => double.tryParse(value.trim());
    switch (key) {
      case 'sub-font-size':
        final v = n();
        return v == null || v <= 0 ? this : _copy(fontSize: v);
      case 'sub-scale':
        final v = n();
        return v == null || v <= 0 ? this : _copy(scale: v);
      case 'sub-pos':
        final v = n();
        return v == null ? this : _copy(position: v.clamp(0, 150).toDouble());
      case 'sub-margin-y':
        final v = n();
        return v == null ? this : _copy(marginY: v.clamp(0, 400).toDouble());
      case 'sub-color':
        return _copy(color: parseMpvColor(value) ?? color);
      case 'sub-border-color':
      case 'sub-outline-color':
        return _copy(borderColor: parseMpvColor(value) ?? borderColor);
      case 'sub-border-size':
      case 'sub-outline-size':
        final v = n();
        return v == null ? this : _copy(borderSize: v.clamp(0, 20).toDouble());
      case 'sub-shadow-color':
        return _copy(shadowColor: parseMpvColor(value) ?? shadowColor);
      case 'sub-shadow-offset':
        final v = n();
        return v == null
            ? this
            : _copy(shadowOffset: v.clamp(0, 20).toDouble());
      case 'sub-back-color':
        return _copy(backColor: parseMpvColor(value) ?? backColor);
      case 'sub-bold':
        return _copy(bold: value == 'yes');
      case 'sub-font':
        return _copy(font: _flutterFont(value), fontSet: true);
    }
    return this;
  }

  /// libmpv's `sub-font` as a Flutter family: the generic names map to
  /// Android's; a file path or a name Flutter cannot load falls back to
  /// the system font rather than to nothing.
  static String? _flutterFont(String v) {
    final s = v.trim();
    if (s.isEmpty || s.contains('/') || s.toLowerCase().endsWith('.ttf')) {
      return null;
    }
    switch (s.toLowerCase()) {
      case 'sans-serif':
      case 'sans':
      case 'default':
        return null;
      case 'serif':
        return 'serif';
      case 'monospace':
      case 'mono':
        return 'monospace';
    }
    return s;
  }

  SubtitleLook _copy({
    double? fontSize,
    double? scale,
    double? position,
    double? marginY,
    Color? color,
    Color? borderColor,
    double? borderSize,
    Color? shadowColor,
    double? shadowOffset,
    Color? backColor,
    String? font,
    bool fontSet = false,
    bool? bold,
  }) =>
      SubtitleLook(
        fontSize: fontSize ?? this.fontSize,
        scale: scale ?? this.scale,
        position: position ?? this.position,
        marginY: marginY ?? this.marginY,
        color: color ?? this.color,
        borderColor: borderColor ?? this.borderColor,
        borderSize: borderSize ?? this.borderSize,
        shadowColor: shadowColor ?? this.shadowColor,
        shadowOffset: shadowOffset ?? this.shadowOffset,
        backColor: backColor ?? this.backColor,
        font: fontSet ? font : this.font,
        bold: bold ?? this.bold,
      );

  @override
  bool operator ==(Object other) =>
      other is SubtitleLook &&
      other.fontSize == fontSize &&
      other.scale == scale &&
      other.position == position &&
      other.marginY == marginY &&
      other.color == color &&
      other.borderColor == borderColor &&
      other.borderSize == borderSize &&
      other.shadowColor == shadowColor &&
      other.shadowOffset == shadowOffset &&
      other.backColor == backColor &&
      other.font == font &&
      other.bold == bold;

  @override
  int get hashCode => Object.hash(
      fontSize,
      scale,
      position,
      marginY,
      color,
      borderColor,
      borderSize,
      shadowColor,
      shadowOffset,
      backColor,
      font,
      bold);
}

/// A libmpv colour — `#RRGGBB` or `#AARRGGBB` — or null if it is neither.
Color? parseMpvColor(String v) {
  var s = v.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) s = 'FF$s';
  if (s.length != 8) return null;
  final n = int.tryParse(s, radix: 16);
  return n == null ? null : Color(n);
}
