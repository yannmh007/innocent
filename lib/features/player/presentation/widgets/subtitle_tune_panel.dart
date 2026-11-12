import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// v1.63 — adjust subtitles WITHOUT leaving the video.
///
/// WHY THIS EXISTS. Timing, size and position were all reachable only from
/// Settings, three screens away from the one place you ever notice they are
/// wrong: mid-scene, with the subtitle a second late. MX Player's answer is
/// gestures on the video itself; this is the same capability reached a safer
/// way.
///
/// WHY NOT GESTURES ON THE VIDEO. The player's gesture layer already carries
/// brightness, volume, seek, long-press speed, double-tap skip and pinch zoom,
/// each with its own enable switch and its own edge cases. Adding a mode on
/// top of that router risks the gestures people use every single day for one
/// they use occasionally. So the drags live INSIDE this panel, where they
/// cannot reach the router at all:
///
///   drag horizontally  → timing   (right = subtitle later)
///   drag vertically    → position (down = subtitle lower)
///   the size row       → text size
///
/// The video keeps playing underneath — the panel is deliberately short and
/// bottom-aligned — so every change is judged against the picture it is meant
/// to fix, which is the whole point.
class SubtitleTunePanel extends StatefulWidget {
  final int initialDelayMs;
  final double initialScale;
  final int initialVerticalPos;

  final ValueChanged<int> onDelayChanged;
  final ValueChanged<double> onScaleChanged;
  final ValueChanged<int> onVerticalPosChanged;

  const SubtitleTunePanel({
    super.key,
    required this.initialDelayMs,
    required this.initialScale,
    required this.initialVerticalPos,
    required this.onDelayChanged,
    required this.onScaleChanged,
    required this.onVerticalPosChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required int initialDelayMs,
    required double initialScale,
    required int initialVerticalPos,
    required ValueChanged<int> onDelayChanged,
    required ValueChanged<double> onScaleChanged,
    required ValueChanged<int> onVerticalPosChanged,
  }) {
    return showPlayerSheet<void>(
      context,
      // The video must stay visible and playing behind it: this panel exists
      // to be judged against the picture.
      barrierColor: Colors.transparent,
      builder: (_) => SubtitleTunePanel(
        initialDelayMs: initialDelayMs,
        initialScale: initialScale,
        initialVerticalPos: initialVerticalPos,
        onDelayChanged: onDelayChanged,
        onScaleChanged: onScaleChanged,
        onVerticalPosChanged: onVerticalPosChanged,
      ),
    );
  }

  @override
  State<SubtitleTunePanel> createState() => _SubtitleTunePanelState();
}

class _SubtitleTunePanelState extends State<SubtitleTunePanel> {
  static const int _delayMin = -20000;
  static const int _delayMax = 20000;
  // These MUST match IntSetting.subtitleScale (10–200, stored as percent) and
  // IntSetting.subtitleVerticalPos (0–100). ExtraSettingsService.setInt clamps
  // silently, so a wider range here would not throw — it would quietly lie:
  // the panel would show 130%, the store would keep 100%, and reopening the
  // panel would show a number the user never chose.
  static const double _scaleMin = 0.1;
  static const double _scaleMax = 2.0;
  static const int _posMin = 0;
  static const int _posMax = 100;

  late int _delayMs;
  late double _scale;
  late int _pos;

  /// Drag accumulators. A drag reports pixels; these convert to units and keep
  /// the remainder, so a slow drag still moves and a fast one does not
  /// overshoot.
  double _dragDx = 0;
  double _dragDy = 0;

  @override
  void initState() {
    super.initState();
    _delayMs = widget.initialDelayMs.clamp(_delayMin, _delayMax);
    _scale = widget.initialScale.clamp(_scaleMin, _scaleMax);
    _pos = widget.initialVerticalPos.clamp(_posMin, _posMax);
  }

  void _setDelay(int v) {
    final next = v.clamp(_delayMin, _delayMax);
    if (next == _delayMs) return;
    setState(() => _delayMs = next);
    widget.onDelayChanged(next);
  }

  void _setScale(double v) {
    final next = double.parse(v.clamp(_scaleMin, _scaleMax).toStringAsFixed(2));
    if (next == _scale) return;
    setState(() => _scale = next);
    widget.onScaleChanged(next);
  }

  void _setPos(int v) {
    final next = v.clamp(_posMin, _posMax);
    if (next == _pos) return;
    setState(() => _pos = next);
    widget.onVerticalPosChanged(next);
  }

  // 8 logical pixels per 100 ms keeps a full-width drag worth about ±5 s,
  // which covers the mistimings people actually meet without making a
  // fingertip's wobble jump half a second.
  void _onPanUpdate(DragUpdateDetails d) {
    _dragDx += d.delta.dx;
    _dragDy += d.delta.dy;
    const pxPerStep = 8.0;
    while (_dragDx.abs() >= pxPerStep) {
      final sign = _dragDx > 0 ? 1 : -1;
      _dragDx -= sign * pxPerStep;
      _setDelay(_delayMs + sign * 100);
    }
    const pxPerPos = 6.0;
    while (_dragDy.abs() >= pxPerPos) {
      final sign = _dragDy > 0 ? 1 : -1;
      _dragDy -= sign * pxPerPos;
      _setPos(_pos + sign);
    }
  }

  String _fmtDelay(int ms) {
    final sec = ms / 1000;
    return '${sec > 0 ? '+' : ''}${sec.toStringAsFixed(1)}s';
  }

  /// One setting: its name on the left, − value + on the right, every
  /// row's steppers in one column. A tap on the value puts it back.
  Widget _row({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
    required VoidCallback onReset,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Icon(icon, color: PlayerUi.textSecondary, size: 22),
          const SizedBox(width: 16),
          Expanded(child: Text(label, style: PlayerUi.rowTitle)),
          _StepButton(
            icon: Icons.remove_rounded,
            onPressed: onMinus,
            tooltip: AppStrings.of(context).pwDecrease(label),
          ),
          SizedBox(
            width: 76,
            child: GestureDetector(
              // Tapping the number resets that one row. Cheap to reach, and
              // obvious once found — the value is the thing you are staring at.
              onTap: onReset,
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: PlayerUi.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add_rounded,
            onPressed: onPlus,
            tooltip: AppStrings.of(context).pwIncrease(label),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: GestureDetector(
        onPanUpdate: _onPanUpdate,
        onPanEnd: (_) {
          _dragDx = 0;
          _dragDy = 0;
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PlayerSheetHeader(
              title: AppStrings.of(context)
                  .subtitleDelayMenu
                  .replaceAll('\n', ' '),
              divider: false,
              trailing: PanelHeaderAction(
                label: AppStrings.of(context).done,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            // Scrolls only where it does not fit (a 320 dp phone held
            // sideways): with room to spare a scroll view takes no drag, so
            // the panel's own drags still reach the timing and position.
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                    PlayerUi.pad(context), 0, PlayerUi.pad(context) - 8, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      AppStrings.of(context).pwTuneHint,
                      style: PlayerUi.rowValue.copyWith(fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    _row(
                      icon: Icons.schedule,
                      label: AppStrings.of(context).pwTiming,
                      value: _fmtDelay(_delayMs),
                      onMinus: () => _setDelay(_delayMs - 100),
                      onPlus: () => _setDelay(_delayMs + 100),
                      onReset: () => _setDelay(0),
                    ),
                    _row(
                      icon: Icons.format_size,
                      label: AppStrings.of(context).size,
                      value: '${(_scale * 100).round()}%',
                      onMinus: () => _setScale(_scale - 0.05),
                      onPlus: () => _setScale(_scale + 0.05),
                      onReset: () => _setScale(1.0),
                    ),
                    _row(
                      icon: Icons.swap_vert,
                      label: AppStrings.of(context).pwPosition,
                      value: '$_pos%',
                      onMinus: () => _setPos(_pos - 1),
                      onPlus: () => _setPos(_pos + 1),
                      onReset: () => _setPos(100),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// − or + of a stepper: a 40 dp tonal circle.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      style: IconButton.styleFrom(
        backgroundColor: PlayerUi.raised,
        foregroundColor: PlayerUi.textPrimary,
        fixedSize: const Size(40, 40),
        minimumSize: const Size(40, 40),
      ),
    );
  }
}
