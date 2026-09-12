// WCAG contrast helpers, shared by the theme and AppBar legibility tests.
//
// These assert on a *ratio* rather than on a specific colour on purpose. The
// bugs they guard were never "this should have been white" — they were "this
// combination cannot be read", and a ratio is the only form of that statement
// that survives someone legitimately changing a shade.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 2.x relative luminance.
double luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

/// WCAG 2.x contrast ratio, 1.0 (identical) to 21.0 (black on white).
double contrastRatio(Color a, Color b) {
  final double la = luminance(a);
  final double lb = luminance(b);
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// WCAG AA for normal-size text. The regressions these tests exist for scored
/// 1.19:1, so the exact threshold matters far less than having one at all.
const double kMinContrast = 4.5;

/// Fails with the measured ratio in the message, because "expected true, got
/// false" would send the next reader back to a calculator.
void expectLegible(
  Color foreground,
  Color background, {
  required String what,
  required String where,
}) {
  final double ratio = contrastRatio(foreground, background);
  expect(
    ratio,
    greaterThan(kMinContrast),
    reason: '$what is illegible in $where — '
        '${ratio.toStringAsFixed(2)}:1, needs > $kMinContrast:1',
  );
}
