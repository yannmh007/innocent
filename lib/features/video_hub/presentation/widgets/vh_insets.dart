import 'package:flutter/material.dart';

/// System-bar insets, in one place.
///
/// WHY THIS EXISTS: Android 15 (API 35) enforces edge-to-edge for every app
/// that targets it. The window now spans the whole display and draws BEHIND
/// the status and navigation bars - which is why the Recent/Home/Back bar was
/// sitting on top of the last row of posters.
///
/// The wrong fix is `SafeArea(bottom: true)` around everything: that pushes
/// the whole scroll view up, leaves a dead band the artwork never reaches, and
/// throws away the look the platform is asking for.
///
/// The right fix, and the one the Flutter issue thread converged on after the
/// global approaches failed, is per-scrollable: let the view run edge to edge
/// and give its CONTENT bottom padding equal to the inset. Artwork scrolls
/// behind the bar; nothing ever ENDS underneath it.
///
/// [MediaQuery.viewPaddingOf] rather than `padding`: `padding` is reduced to
/// zero while the keyboard is open, so a form would lose its clearance at
/// exactly the moment it is being typed into. `viewPadding` reports the
/// physical inset regardless.
/// NOTE ON THE NAME: `core/utils/vh_insets.dart` already owns
/// `SystemInsets`, and it solves a DIFFERENT problem - snapshotting the
/// nav-bar height for the immersive fullscreen player, where Flutter reports
/// the inset as zero because the bars are hidden. This one is about ordinary
/// screens under Android 15 edge-to-edge. Two concerns, two classes, two
/// names - sharing the name would have compiled fine until the first file
/// imported both.
class VhInsets {
  VhInsets._();

  /// Height of the navigation bar - about 48dp with three buttons, about 16dp
  /// with gesture navigation, 0 where there is none.
  static double bottom(BuildContext context) =>
      MediaQuery.viewPaddingOf(context).bottom;

  static double top(BuildContext context) =>
      MediaQuery.viewPaddingOf(context).top;

  /// Bottom padding for a scrollable's LAST item: the system inset plus the
  /// breathing room the design wanted anyway.
  ///
  /// Additive, not either/or: a phone with gesture navigation reports a small
  /// inset, and using it alone would leave the final row almost touching the
  /// screen edge.
  static double scrollBottom(BuildContext context, {double extra = 24}) =>
      bottom(context) + extra;

  /// Padding for a bottom sheet, which sits above the navigation bar rather
  /// than behind it.
  static EdgeInsets sheet(BuildContext context, {double extra = 16}) =>
      EdgeInsets.only(bottom: bottom(context) + extra);
}
