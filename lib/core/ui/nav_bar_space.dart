import 'package:flutter/widgets.dart';

/// Room for the phone's navigation bar under the last thing on a screen.
///
/// The app draws edge to edge (main.dart): every screen runs behind the
/// Back · Home · Recents bar. A ListView or GridView left without `padding`
/// makes this room by itself; one given an explicit `padding` — and every
/// SingleChildScrollView and CustomScrollView — does not, so the last row
/// or button of a long screen came to rest under the bar, out of reach
/// (App update with long release notes: Download sat behind Back · Home).
///
/// The room is the bar's height as this context sees it: about 48 with
/// three buttons, about 16 with gestures, 0 inside a tab (the shell's
/// bottom bar already stands above it), inside a sheet from
/// showAppModalBottomSheet, or while the keyboard is up. So adding it never
/// pushes anything up twice.
double navBarSpace(BuildContext context) =>
    MediaQuery.paddingOf(context).bottom;

extension NavBarSpacePadding on EdgeInsets {
  /// This padding with [navBarSpace] added at the bottom.
  EdgeInsets plusNavBar(BuildContext context) =>
      copyWith(bottom: bottom + navBarSpace(context));
}
