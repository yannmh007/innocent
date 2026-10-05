import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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

/// The system bars' and the camera cutout's insets for the current
/// orientation, read from Android even while the immersive player hides the
/// bars (`getInsetsIgnoringVisibility`). Flutter reports a hidden bar as
/// zero, which is why the player's controls used to run edge to edge in
/// landscape — under the camera hole and where the side nav bar appears —
/// while MX keeps them inside these insets.
class StableInsets {
  StableInsets._();

  static const MethodChannel _channel = MethodChannel('mx_clone/pip');

  /// Zero when unknown (not Android, an old OS, an error): the layout then
  /// falls back to what Flutter reports, which is what it always used.
  static Future<EdgeInsets> read() async {
    if (kIsWeb || !Platform.isAndroid) return EdgeInsets.zero;
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('stableInsets');
      if (m == null) return EdgeInsets.zero;
      double v(String k) {
        final x = m[k];
        return x is num && x.isFinite && x >= 0 && x < 200 ? x.toDouble() : 0;
      }

      return EdgeInsets.fromLTRB(v('left'), v('top'), v('right'), v('bottom'));
    } catch (_) {
      return EdgeInsets.zero;
    }
  }
}
