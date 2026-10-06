import 'package:flutter/painting.dart';

/// The heading of each bottom tab — Video (Folders), Music, Transfer, Me.
///
/// ONE size and weight for all four, so switching tabs does not make the
/// heading jump. They had drifted apart one screen at a time: Folders was
/// 17 sp bold, Music 20 sp medium (the AppBar theme's), Transfer 20 sp bold
/// and Me 20 sp bold — the owner saw it at once (2026-10-06). 20 sp bold is
/// MX Player's tab title. No colour here: each screen keeps its own.
const TextStyle kTabTitleStyle = TextStyle(
  fontSize: 20,
  fontWeight: FontWeight.w700,
  letterSpacing: 0,
);
