import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/localization/app_strings.dart';
/// The Innocent brand mark, drawn entirely in code — no image asset.
///
/// v0.49.3 — redrawn 1:1 from the reference artwork (Innocent.png,
/// 3464×3464). Every number below was *measured* off that file:
///
///   mark box ............ 971 × 1880 px  →  aspect W/H = 0.5165
///   red fill ............ #F00000        dark fill ....... #383838
///   outline ............. #FFFFFF, ~10 px (0.0053 · H), round joins
///   drop shadow ......... #434343 @ α .73, blur σ ≈ 0.006 · H,
///                         offset ≈ (0.008 · H, 0.011 · H)  → light
///                         comes from the top-left, exactly like the PNG
///   top/bottom bar ...... v 0 – 0.221  and  v 0.785 – 1.0
///   stem ................ u 0.222 – 0.778
///   RED diagonal ........ 45° in *pixels*:  u = 0.9506 − 1.936 · v
///   DARK diagonal ....... u = 1.0000 − 1.936 · (v − 0.0202)
///     → the two shapes never touch; the perpendicular air gap between
///       them is ≈ 61 px (0.032 · H) — the little "ဟ" the design has
///       along the split.
///   red wedge tip ....... (0.222, 0.376) — a sharp point on stem-left
///   dark top vertex ..... (1.000, 0.020)
///   corner radii ........ top outer 0.0239·H · bottom outer 0.0255·H ·
///                         bar-bottom outer 0.0160·H · bottom-bar top
///                         outer 0.0106·H · inner notches sharp
///
/// The wordmark matches the artwork too: #F5E9E9 fill with a #D50000
/// contour, W800, wide tracking — no glow.
class InnocentLogo extends StatelessWidget {
  /// Side length of the square canvas the mark is centred in
  /// (the wordmark, if shown, sits below).
  final double size;

  /// Whether to render the "INNOCENT" wordmark beneath the mark.
  final bool showWordmark;

  /// Mark body fill (defaults to [body]).
  final Color? bodyColor;

  /// Diagonal wedge + wordmark contour (defaults to [accent]).
  final Color? accentColor;

  /// Mark outline (defaults to [outline]).
  final Color? outlineColor;

  const InnocentLogo({
    super.key,
    this.size = 120,
    this.showWordmark = false,
    this.bodyColor,
    this.accentColor,
    this.outlineColor,
  });

  /// Brand red — sampled #F00000.
  static const Color accent = Color(0xFFF00000);

  /// Mark body — sampled #383838.
  static const Color body = Color(0xFF383838);

  /// Hairline outline — pure white in the artwork.
  static const Color outline = Color(0xFFFFFFFF);

  /// Wordmark letter fill — sampled #F5E9E9.
  static const Color wordmarkFill = Color(0xFFF5E9E9);

  /// Wordmark contour — sampled #D50000.
  static const Color wordmarkStroke = Color(0xFFD50000);

  @override
  Widget build(BuildContext context) {
    final bodyC = bodyColor ?? body;
    final accentC = accentColor ?? accent;
    final outlineC = outlineColor ?? outline;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _MarkPainter(
              body: bodyC,
              accent: accentC,
              outline: outlineC,
            ),
          ),
        ),
        if (showWordmark) ...[
          // Measured: 264 px gap under a 1880 px mark → 0.14 · markH.
          SizedBox(height: size * _LogoGeometry.markH * 0.14),
          _Wordmark(
            // Cap height 256 px → fontSize ≈ 355 px → 0.189 · markH.
            fontSize: size * _LogoGeometry.markH * 0.19,
            fill: wordmarkFill,
            stroke: accentColor == null ? wordmarkStroke : accentC,
          ),
        ],
      ],
    );
  }
}

/// All measured constants in one place. u = fraction of mark WIDTH,
/// v = fraction of mark HEIGHT. The mark box itself is centred in the
/// square widget canvas at [markH] of its side.
class _LogoGeometry {
  _LogoGeometry._();

  /// Mark height as a fraction of the square canvas side.
  static const double markH = 0.88;

  /// Mark aspect ratio (width / height) = 971 / 1880.
  static const double aspect = 0.5165;

  // Horizontal structure.
  static const double stemL = 0.2224;
  static const double stemR = 0.7785;

  // Vertical structure.
  static const double barB = 0.2213; // top bar bottom
  static const double botT = 0.7851; // bottom bar top

  // The two 45°-in-pixels diagonals: u = c − k · v, with k = H / W.
  static const double k = 1.936;
  static const double redTopU = 0.9506; // red diagonal at v = 0
  static const double darkTopV = 0.0202; // dark diagonal at u = 1
  static const double redTipV = 0.3760; // red wedge tip on stem-left
  static const double darkHitV = 0.4218; // dark diagonal meets stem-left

  // Corner radii, fractions of mark HEIGHT.
  static const double rTop = 0.0239; // top bar outer top corners
  static const double rBottom = 0.0255; // bottom bar outer bottom corners
  static const double rBarBtm = 0.0160; // top bar outer bottom corners
  static const double rBotTop = 0.0106; // bottom bar outer top corners

  // Paint treatment, fractions of mark HEIGHT.
  static const double strokeW = 0.0053;
  static const double shadowDx = 0.008;
  static const double shadowDy = 0.011;
  static const double shadowSigma = 0.006;
  static const Color shadowColor = Color(0xBA434343); // α ≈ .73, sampled
}

/// Builds the two measured paths for a given mark rectangle
/// (static-only helper).
class _MarkPaths {
  _MarkPaths._();

  static double _x(Rect m, double u) => m.left + u * m.width;
  static double _y(Rect m, double v) => m.top + v * m.height;

  /// Red shape: top-bar left portion + the downward wedge, bounded on the
  /// right by the RED diagonal. Clockwise from the wedge tip.
  static Path _red(Rect m) {
    final rT = _LogoGeometry.rTop * m.height;
    final rS = _LogoGeometry.rBarBtm * m.height;
    final p = Path()
      ..moveTo(_x(m, _LogoGeometry.stemL), _y(m, _LogoGeometry.redTipV))
      // up the stem's left edge (inner corner: sharp)
      ..lineTo(_x(m, _LogoGeometry.stemL), _y(m, _LogoGeometry.barB))
      // left along the bar's underside → small outer round
      ..lineTo(m.left + rS, _y(m, _LogoGeometry.barB))
      ..arcToPoint(Offset(m.left, _y(m, _LogoGeometry.barB) - rS),
          radius: Radius.circular(rS))
      // up the left edge → big top-left round
      ..lineTo(m.left, m.top + rT)
      ..arcToPoint(Offset(m.left + rT, m.top), radius: Radius.circular(rT))
      // along the top edge to where the diagonal starts
      ..lineTo(_x(m, _LogoGeometry.redTopU), m.top);
    // down the 45° diagonal back to the tip (join rounding softens both
    // sharp ends exactly like the artwork's tiny ~8 px tips)
    p.close();
    return p;
  }

  /// Dark shape: top-bar right sliver + stem + full bottom bar, bounded on
  /// the upper-left by the DARK diagonal. Clockwise from the top vertex.
  static Path _dark(Rect m) {
    final rS = _LogoGeometry.rBarBtm * m.height;
    final rQ = _LogoGeometry.rBotTop * m.height;
    final rB = _LogoGeometry.rBottom * m.height;
    final p = Path()
      ..moveTo(m.right, _y(m, _LogoGeometry.darkTopV))
      // down the right edge → small outer round onto the bar's underside
      ..lineTo(m.right, _y(m, _LogoGeometry.barB) - rS)
      ..arcToPoint(Offset(m.right - rS, _y(m, _LogoGeometry.barB)),
          radius: Radius.circular(rS))
      // in to the stem, then down it (inner corners sharp)
      ..lineTo(_x(m, _LogoGeometry.stemR), _y(m, _LogoGeometry.barB))
      ..lineTo(_x(m, _LogoGeometry.stemR), _y(m, _LogoGeometry.botT))
      // out to the bottom bar's right → tiny outer round
      ..lineTo(m.right - rQ, _y(m, _LogoGeometry.botT))
      ..arcToPoint(Offset(m.right, _y(m, _LogoGeometry.botT) + rQ),
          radius: Radius.circular(rQ))
      // bottom-right big round
      ..lineTo(m.right, m.bottom - rB)
      ..arcToPoint(Offset(m.right - rB, m.bottom), radius: Radius.circular(rB))
      // bottom edge, bottom-left big round
      ..lineTo(m.left + rB, m.bottom)
      ..arcToPoint(Offset(m.left, m.bottom - rB), radius: Radius.circular(rB))
      // up to the bottom bar's top-left → tiny outer round
      ..lineTo(m.left, _y(m, _LogoGeometry.botT) + rQ)
      ..arcToPoint(Offset(m.left + rQ, _y(m, _LogoGeometry.botT)),
          radius: Radius.circular(rQ))
      // in to the stem and up its left edge to the diagonal
      ..lineTo(_x(m, _LogoGeometry.stemL), _y(m, _LogoGeometry.botT))
      ..lineTo(_x(m, _LogoGeometry.stemL), _y(m, _LogoGeometry.darkHitV));
    // up-right along the 45° diagonal back to the top vertex
    p.close();
    return p;
  }
}

class _Wordmark extends StatelessWidget {
  final double fontSize;
  final Color fill;
  final Color stroke;
  const _Wordmark({
    required this.fontSize,
    required this.fill,
    required this.stroke,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w800,
      letterSpacing: fontSize * 0.18, // measured tracking
    );
    // Contour under fill — the artwork's outlined-letter look.
    return Stack(
      children: [
        Text(
          'INNOCENT',
          style: style.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = fontSize * 0.02
              ..color = stroke,
          ),
        ),
        Text('INNOCENT', style: style.copyWith(color: fill)),
      ],
    );
  }
}

/// Paints the measured two-piece mark: soft drop shadow first, then the
/// dark piece, then the red piece — each filled and hairline-stroked.
class _MarkPainter extends CustomPainter {
  final Color body;
  final Color accent;
  final Color outline;
  const _MarkPainter({
    required this.body,
    required this.accent,
    required this.outline,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Centre a 0.5165-aspect mark box in the square canvas.
    final h = size.height * _LogoGeometry.markH;
    final w = h * _LogoGeometry.aspect;
    final m = Rect.fromCenter(
        center: size.center(Offset.zero), width: w, height: h);

    final red = _MarkPaths._red(m);
    final dark = _MarkPaths._dark(m);

    // 1) Drop shadow — both pieces, offset to the lower-right and blurred,
    //    so the diagonal gap shows the red edge's shadow like the PNG.
    final shadow = Paint()
      ..color = _LogoGeometry.shadowColor
      ..maskFilter = ui.MaskFilter.blur(
          ui.BlurStyle.normal, _LogoGeometry.shadowSigma * h);
    canvas.save();
    canvas.translate(
        _LogoGeometry.shadowDx * h, _LogoGeometry.shadowDy * h);
    canvas.drawPath(dark, shadow);
    canvas.drawPath(red, shadow);
    canvas.restore();

    // 2) Fills + hairline white outline (round joins soften the two
    //    diagonal tips exactly like the artwork).
    final strokeW =
        (_LogoGeometry.strokeW * h).clamp(1.0, double.infinity);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeJoin = StrokeJoin.round
      ..color = outline;

    canvas.drawPath(dark, Paint()..color = body);
    canvas.drawPath(dark, stroke);
    canvas.drawPath(red, Paint()..color = accent);
    canvas.drawPath(red, stroke);
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) =>
      old.body != body || old.accent != accent || old.outline != outline;
}
