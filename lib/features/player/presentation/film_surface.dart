/// When a film may be drawn on Android's own SurfaceView under the player
/// instead of on Flutter's texture (P1, the owner's choice of 28 Nov 2026;
/// docs/handoff_2026_11_29_beyond_mx_p2.md §3-§4).
///
/// On the SurfaceView the display composes the film and Flutter draws only
/// when its controls change (Test Lab 46124628533: app CPU realme 61 → 39 %,
/// OPPO 52 → ~42 % of a core). Whatever needs the picture INSIDE Flutter's
/// scene sends it back to the texture while it is on:
///  * Display's colour filters (brightness, contrast, saturation, hue,
///    gamma: one colour matrix over the picture) — the owner's word;
///  * the mirror and the vertical flip (a negative scale, which a
///    SurfaceView does not take);
///  * the picture hidden (Video display off), before its size is known
///    (nowhere to place it), and while the player's route moves in or out
///    (the route under it is drawn then, and would cover the film).
/// Night mode is a black layer over the picture, which works on both.
bool filmSurfaceAllowed({
  required bool videoShown,
  required bool sizeKnown,
  required bool mirror,
  required bool flip,
  required bool colourNeutral,
  required bool routeIn,
}) =>
    videoShown && sizeKnown && !mirror && !flip && colourNeutral && routeIn;

/// Night mode (picture) as MX 3.4.3 draws it: the picture at 40 %, every
/// colour alike (the reference lab, run 45862946745: a white frame read 102
/// of 255) — black at 60 % over it, which is the same as scaling each
/// channel by 0.4 and is drawn over a film on its own SurfaceView as well
/// as over the texture.
const int nightShadeArgb = 0x99000000;
