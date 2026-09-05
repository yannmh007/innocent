/// Remembers the device's real system-bar insets captured while the bars are
/// actually visible.
///
/// The fullscreen player runs in `immersiveSticky`, which HIDES the status and
/// navigation bars — and while they're hidden Flutter reports their inset as
/// zero. But in sticky mode a tap (to reveal the player controls) also makes
/// the system bars slide back in transiently, so if the bottom controls sit at
/// inset-zero they end up underneath the reappearing nav bar (Prev/Play/Next
/// overlapping Back/Home/Recent). We can't read the nav-bar height while it's
/// hidden, so we snapshot it earlier — when the app is on a normal
/// edge-to-edge screen with the bars visible — and reserve that much space in
/// the player, which keeps the controls clear of the bar on every device
/// (3-button, 2-button, or gesture) instead of hard-coding a guess.
class SystemInsets {
  SystemInsets._();

  /// Largest bottom system-bar inset (logical px) seen while bars were shown.
  static double bottomBar = 0.0;

  /// Feed the current bottom viewPadding in; keeps the maximum so a later
  /// immersive frame reporting 0 doesn't wipe the real value.
  static void observeBottom(double inset) {
    if (inset > bottomBar) bottomBar = inset;
  }
}
