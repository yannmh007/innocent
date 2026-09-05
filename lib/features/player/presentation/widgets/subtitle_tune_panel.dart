import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

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
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      // The video must stay visible and playing behind it: this panel exists
      // to be judged against the picture.
      barrierColor: Colors.transparent,
      isScrollControlled: true,
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

  Widget _row({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
    required VoidCallback onReset,
  }) {
    return Row(
      children: [
        Icon(icon, color: Colors.white70, size: 20),
        const SizedBox(width: 10),
        SizedBox(
          width: 74,
          child: Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ),
        IconButton(
          icon: const Icon(Icons.remove, color: Colors.white),
          onPressed: onMinus,
          tooltip: 'Decrease $label',
        ),
        Expanded(
          child: GestureDetector(
            // Tapping the number resets that one row. Cheap to reach, and
            // obvious once found — the value is the thing you are staring at.
            onTap: onReset,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add, color: Colors.white),
          onPressed: onPlus,
          tooltip: 'Increase $label',
        ),
      ],
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
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xE6111111),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Drag anywhere on this panel — sideways for timing, '
                'up and down for position. Tap a value to reset it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 11.5),
              ),
              const SizedBox(height: 6),
              _row(
                icon: Icons.schedule,
                label: 'Timing',
                value: _fmtDelay(_delayMs),
                onMinus: () => _setDelay(_delayMs - 100),
                onPlus: () => _setDelay(_delayMs + 100),
                onReset: () => _setDelay(0),
              ),
              _row(
                icon: Icons.format_size,
                label: 'Size',
                value: '${(_scale * 100).round()}%',
                onMinus: () => _setScale(_scale - 0.05),
                onPlus: () => _setScale(_scale + 0.05),
                onReset: () => _setScale(1.0),
              ),
              _row(
                icon: Icons.swap_vert,
                label: 'Position',
                value: '$_pos%',
                onMinus: () => _setPos(_pos - 1),
                onPlus: () => _setPos(_pos + 1),
                onReset: () => _setPos(100),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.primaryBlue,
                  ),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
