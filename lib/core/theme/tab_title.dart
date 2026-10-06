import 'package:flutter/painting.dart';

/// The title of EVERY app bar — the four tabs (Video, Music, Transfer, Me)
/// and every screen opened from them.
///
/// ONE size and weight everywhere, so moving between screens never makes the
/// heading jump. They had drifted apart one screen at a time — 15, 17, 18, 19,
/// 20 and 21 sp, medium, semibold and bold — and the owner saw it at once
/// (2026-10-06). 20 sp bold is MX Player's. No colour here: a screen with its
/// own bar colour keeps its own text colour. The AppBar theme
/// (lib/core/theme/app_theme.dart) uses the same values, so a plain
/// `AppBar(title: Text(...))` gets it with no style at all.
const TextStyle kAppBarTitleStyle = TextStyle(
  fontSize: 20,
  fontWeight: FontWeight.w700,
  letterSpacing: 0,
);

/// The tabs' name for it (the same style).
const TextStyle kTabTitleStyle = kAppBarTitleStyle;
