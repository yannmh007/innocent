import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Design tokens for the Video Hub.
///
/// WHY: the first cut sized everything by eye — 12.5, 13, 16, 17px type;
/// 5, 6, 8, 10, 14, 16, 18px gaps. Nothing was wrong individually and the
/// whole read as amateur, because "premium" in an interface is mostly the
/// absence of arbitrary numbers. A reader cannot name the rhythm, but they
/// feel it when there is not one.
///
/// Two rules are enforced here:
///
/// 1. SPACING IS A 4dp SCALE. Every gap is one of six values. Anything that
///    needs a seventh is a sign the layout is wrong, not that the scale is
///    short.
///
/// 2. HIERARCHY COMES FROM LUMINANCE, NOT WEIGHT. On a dark canvas, shadows
///    do not read and stacking bold weights just makes everything shout. So
///    importance is carried by how bright a thing is: primary text is white,
///    secondary is dimmed, tertiary is dimmer still, and surfaces step up in
///    tone rather than casting shadows.
class VH {
  VH._();

  // ---- spacing (4dp scale) ------------------------------------------------
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;

  /// Horizontal page margin. One number, used by every screen in the feature.
  static const double gutter = 16;

  // ---- radii --------------------------------------------------------------
  static const double rCard = 10;
  static const double rControl = 10;
  static const double rPill = 999;
  static const double rSheet = 20;

  // ---- tonal surfaces -----------------------------------------------------
  /// The page itself (true black — this app is AMOLED-first).
  static const Color canvas = AppColors.specScaffold;

  /// One step up: controls at rest, chips, the search field.
  static const Color surface1 = Color(0xFF17191D);

  /// Two steps up: sheets, menus, anything floating over the page.
  static const Color surface2 = Color(0xFF1F2228);

  /// Three steps up: a selected row inside a sheet.
  static const Color surface3 = Color(0xFF2A2E36);

  /// Hairline separation. Borders do the job shadows cannot on dark.
  static const Color hairline = Color(0x14FFFFFF);

  // ---- text luminance ramp ------------------------------------------------
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFA8AEB8);
  static const Color textTertiary = Color(0xFF6C7480);

  /// Text drawn ON a light (selected) surface.
  static const Color textInverse = Color(0xFF07080A);

  /// Reserved for genuinely singular moments — the primary action, a live
  /// badge. Deliberately scarce: an accent used everywhere stops being one.
  static const Color accent = AppColors.specPrimary;

  // ---- type scale ---------------------------------------------------------
  /// Hero title.
  static const TextStyle display = TextStyle(
    color: textPrimary,
    fontSize: 26,
    fontWeight: FontWeight.w800,
    height: 1.12,
    letterSpacing: -0.6,
  );

  /// Screen / section heading.
  static const TextStyle heading = TextStyle(
    color: textPrimary,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: -0.3,
  );

  /// Detail-screen title.
  static const TextStyle title = TextStyle(
    color: textPrimary,
    fontSize: 21,
    fontWeight: FontWeight.w700,
    height: 1.18,
    letterSpacing: -0.4,
  );

  /// Control labels — tabs, buttons, chips.
  static const TextStyle label = TextStyle(
    color: textPrimary,
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: -0.1,
  );

  /// Body copy — synopsis, sheet options.
  static const TextStyle body = TextStyle(
    color: textSecondary,
    fontSize: 13.5,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );

  /// Poster card title.
  static const TextStyle cardTitle = TextStyle(
    color: textPrimary,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.2,
    letterSpacing: -0.1,
  );

  /// Year, counts, secondary metadata.
  static const TextStyle meta = TextStyle(
    color: textTertiary,
    fontSize: 10.5,
    fontWeight: FontWeight.w400,
    height: 1.15,
  );

  /// Small all-caps markers — quality, episode count.
  static const TextStyle badge = TextStyle(
    color: textPrimary,
    fontSize: 9,
    fontWeight: FontWeight.w700,
    height: 1.1,
    letterSpacing: 0.4,
  );

  // ---- control heights ----------------------------------------------------
  static const double barHeight = 46;
  static const double toolbarHeight = 44;
  static const double chipHeight = 32;
  static const double controlHeight = 34;

  // ---- motion -------------------------------------------------------------
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration normal = Duration(milliseconds: 220);
  static const Curve ease = Curves.easeOutCubic;
}
