import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/services/diagnostics/cpu_probe.dart';
import '../../../../core/services/diagnostics/playback_log.dart';
import '../widgets/player_ui.dart';

/// DEVICE LAB AND TEST LAB ONLY (`INNOCENT_LAB`) — the player's smoothness
/// as a viewer meets it, timed frame by frame.
///
/// WHY (27 Nov 2026). The owner, on 1.64.89: "⋮'s menu stutters and lags
/// when scrolled". A widget test counts what is rebuilt and repainted, but
/// cannot time a GPU; the emulator's GPU is not a phone's. This opens each
/// menu of the player on the phone itself — the film playing and paused —
/// flings its list up and down with a finger the app makes (the real drag
/// and fling path: pointer events into GestureBinding, as a touch screen
/// sends them), and writes one `LAB frames <state>/<menu>/<look> …` line a
/// moment ([CpuProbe.markEnd]): frames per second, build and raster
/// p50/p90/p99/worst, the frames over 16.7 ms (and over a frame at the
/// display's rate), and the threads' CPU over the same seconds.
///
/// A PLAN is steps separated by spaces, `STATE:MENU:LOOK[:SECONDS]`:
///  * STATE `play` or `pause`;
///  * MENU `more` (⋮), `morepage` (its "More ›" page), `cc`, `audio` (♪),
///    `queue`, `display`, `eq`, `sleep`, `bookmarks`, `shortcuts` (the
///    open shortcut row, scrolled sideways), `controls` (the controls up,
///    nothing scrolled), `film` (nothing over the film);
///  * LOOK a set of [PlayerUi] lab switches ([looks]): `base` is 1.64.89's
///    drawing, `now` the build's own;
///  * SECONDS of scrolling (6 by default; a still MENU is timed as long).
/// One play of every step, in order: the A/B is inside one run on one
/// phone, never across runs (skill device-labs).
class SmoothLab {
  SmoothLab._();

  /// The player screen's, in a lab build: opens MENU (false when it could
  /// not), closes every menu and sheet, plays or pauses the film.
  static Future<bool> Function(String menu)? open;
  static Future<void> Function()? close;
  static Future<void> Function(bool play)? playing;

  /// The default plan: ⋮ in every look, playing then paused; the other
  /// menus and the controls in the two that count.
  static const String defaultPlan =
      'play:film:base:4 play:controls:base:3 play:controls:now:3 '
      'play:more:base play:more:noink play:more:nomask play:more:rb '
      'play:more:rim play:more:now '
      'pause:more:base pause:more:noink pause:more:now '
      'play:morepage:base play:morepage:now '
      'play:cc:base play:cc:now play:audio:base play:audio:now '
      'play:queue:base play:queue:now play:display:base play:display:now '
      'play:shortcuts:base play:shortcuts:now '
      'play:more:base:4 play:more:now:4';

  /// The looks a step can ask for: each sets [PlayerUi]'s lab switches.
  /// `base`: the halo blurred three times (1, 3, 10), the full-panel fade
  /// mask, no repaint boundary round a list, the screen rebuilt on every
  /// position tick — 1.64.89. `now`: the build's own choices.
  static const Map<String, Map<String, Object>> looks = {
    'base': {'ink': 'blur', 'mask': true, 'rb': false, 'tick': true},
    'noink': {'ink': 'none', 'mask': true, 'rb': false, 'tick': true},
    'rim': {'ink': 'rim', 'mask': true, 'rb': false, 'tick': true},
    'nomask': {'ink': 'blur', 'mask': false, 'rb': false, 'tick': true},
    'rb': {'ink': 'blur', 'mask': true, 'rb': true, 'tick': true},
    'notick': {'ink': 'blur', 'mask': true, 'rb': false, 'tick': false},
    'now': <String, Object>{},
  };

  static bool _running = false;

  /// Runs [plan] (or [defaultPlan] for an empty or "1" plan).
  static Future<void> run(String plan) async {
    if (!const bool.fromEnvironment('INNOCENT_LAB') || _running) return;
    _running = true;
    try {
      final steps = (plan.trim().isEmpty || plan.trim() == '1'
              ? defaultPlan
              : plan)
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList();
      PlaybackLog.add('LAB smooth: ${steps.length} steps, '
          'display ${CpuProbe.refreshRate.round()} Hz');
      for (final step in steps) {
        final p = step.split(':');
        if (p.length < 3) continue;
        final seconds = p.length > 3 ? (double.tryParse(p[3]) ?? 6) : 6.0;
        await _step(p[0], p[1], p[2], seconds);
      }
      PlayerUi.labReset();
      PlaybackLog.add('LAB smooth: done');
    } catch (e) {
      PlaybackLog.add('LAB smooth: stopped ($e)');
    } finally {
      _running = false;
    }
  }

  static Future<void> _wait(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  static Future<void> _step(
      String state, String menu, String look, double seconds) async {
    final name = '$state/$menu/$look';
    await close?.call();
    await _wait(400);
    PlayerUi.labLook(looks[look] ?? const <String, Object>{});
    await playing?.call(state != 'pause');
    await _wait(900);
    if (menu != 'film') {
      final ok = await open?.call(menu) ?? false;
      if (!ok) {
        PlaybackLog.add('LAB frames $name: could not open');
        return;
      }
    }
    // The menu in, its fade measured, the first frames of its film drawn.
    await _wait(900);
    final still = menu == 'film' || menu == 'controls';
    final scroll = still ? null : _findScrollable(horizontal: menu == 'shortcuts');
    if (!still && scroll == null) {
      PlaybackLog.add('LAB frames $name: nothing to scroll');
    }
    CpuProbe.markStart(name);
    final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
    if (scroll == null) {
      await _wait((seconds * 1000).round());
    } else {
      var up = true;
      while (DateTime.now().isBefore(end)) {
        await _fling(scroll, up: up);
        up = !up;
        await _wait(700);
      }
    }
    final line = CpuProbe.markEnd();
    if (line == null) PlaybackLog.add('LAB frames $name: no window');
  }

  /// The list the open menu scrolls: the last vertical (or horizontal)
  /// Scrollable laid out on screen — the menu is drawn over the player —
  /// preferring one with somewhere to go.
  static ({Rect rect, Axis axis})? _findScrollable({required bool horizontal}) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    final want = horizontal ? Axis.horizontal : Axis.vertical;
    ({Rect rect, Axis axis})? best;
    var bestRoom = false;
    void visit(Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        final s = e.state as ScrollableState;
        final ro = e.renderObject;
        if (axisDirectionToAxis(s.axisDirection) == want &&
            ro is RenderBox &&
            ro.attached &&
            ro.hasSize &&
            ro.size.width > 40 &&
            ro.size.height > 40) {
          final room = s.position.hasContentDimensions &&
              s.position.maxScrollExtent > 0;
          final at = ro.localToGlobal(Offset.zero) & ro.size;
          if (room || !bestRoom) {
            best = (rect: at, axis: want);
            bestRoom = room;
          }
        }
      }
      e.visitChildren(visit);
    }

    root.visitChildren(visit);
    return best;
  }

  static int _pointer = 7000;

  /// One finger's fling across the list: 28 moves 8 ms apart (a 120 Hz
  /// touch screen's rate) over 300 dp, then let go at speed.
  static Future<void> _fling(({Rect rect, Axis axis}) s, {required bool up}) async {
    final id = ++_pointer;
    final vertical = s.axis == Axis.vertical;
    final c = s.rect.center;
    final reach = (vertical ? s.rect.height : s.rect.width) * 0.3;
    final from = vertical
        ? Offset(c.dx, up ? c.dy + reach : c.dy - reach)
        : Offset(up ? c.dx + reach : c.dx - reach, c.dy);
    final total = vertical
        ? Offset(0, up ? -2 * reach : 2 * reach)
        : Offset(up ? -2 * reach : 2 * reach, 0);
    const moves = 28;
    final clock = Stopwatch()..start();
    final base = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
    Duration t() => base + clock.elapsed;
    final g = GestureBinding.instance;
    g.handlePointerEvent(PointerDownEvent(
        pointer: id, position: from, timeStamp: t(), kind: PointerDeviceKind.touch));
    var at = from;
    for (var i = 1; i <= moves; i++) {
      await _wait(8);
      final next = from + total * (i / moves);
      g.handlePointerEvent(PointerMoveEvent(
          pointer: id,
          position: next,
          delta: next - at,
          timeStamp: t(),
          kind: PointerDeviceKind.touch));
      at = next;
    }
    g.handlePointerEvent(PointerUpEvent(
        pointer: id, position: at, timeStamp: t(), kind: PointerDeviceKind.touch));
  }

  /// Taps the first widget [match] finds on screen (⋮'s "More ›" tile).
  static Future<bool> tap(bool Function(Widget w) match) async {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return false;
    Rect? hit;
    void visit(Element e) {
      if (hit != null) return;
      if (match(e.widget)) {
        final ro = e.renderObject;
        if (ro is RenderBox && ro.attached && ro.hasSize) {
          hit = ro.localToGlobal(Offset.zero) & ro.size;
          return;
        }
      }
      e.visitChildren(visit);
    }

    root.visitChildren(visit);
    final r = hit;
    if (r == null) return false;
    final id = ++_pointer;
    final g = GestureBinding.instance;
    final now = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
    g.handlePointerEvent(PointerDownEvent(
        pointer: id, position: r.center, timeStamp: now, kind: PointerDeviceKind.touch));
    await _wait(60);
    g.handlePointerEvent(PointerUpEvent(
        pointer: id,
        position: r.center,
        timeStamp: now + const Duration(milliseconds: 60),
        kind: PointerDeviceKind.touch));
    return true;
  }
}
