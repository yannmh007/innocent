import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Speed slider — matches MX Player long-press slider (PDF page 9).
/// Phase 15: publishes its on-screen rect via [onBoundsUpdate] so the
/// long-press drag handler can map absolute finger position → speed slot.
class SpeedSlider extends StatefulWidget {
  final double currentSpeed;
  final ValueChanged<double> onSpeedChanged;

  /// Called once after layout with the global rect of the draggable track.
  /// Used by the player provider to interpret long-press drag positions.
  final ValueChanged<Rect>? onBoundsUpdate;

  static const List<double> _speeds = [
    0.25, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0,
  ];

  const SpeedSlider({
    super.key,
    required this.currentSpeed,
    required this.onSpeedChanged,
    this.onBoundsUpdate,
  });

  @override
  State<SpeedSlider> createState() => _SpeedSliderState();
}

class _SpeedSliderState extends State<SpeedSlider> {
  final GlobalKey _trackKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishBounds());
  }

  @override
  void didUpdateWidget(covariant SpeedSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishBounds());
  }

  void _publishBounds() {
    final cb = widget.onBoundsUpdate;
    if (cb == null) return;
    final ctx = _trackKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final topLeft = box.localToGlobal(Offset.zero);
    cb(topLeft & box.size);
  }

  int _nearestIndex(double value) {
    int best = 0;
    double bestDiff = (value - SpeedSlider._speeds[0]).abs();
    for (int i = 1; i < SpeedSlider._speeds.length; i++) {
      final diff = (value - SpeedSlider._speeds[i]).abs();
      if (diff < bestDiff) {
        best = i;
        bestDiff = diff;
      }
    }
    return best;
  }

  String _fmtSpeed(double s) {
    if (s == s.toInt().toDouble()) return s.toInt().toString();
    if (s == 0.25) return '0.25';
    return s.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final selectedIdx = _nearestIndex(widget.currentSpeed);
    const slotWidth = 48.0;
    final totalWidth = SpeedSlider._speeds.length * slotWidth;

    return Center(
      child: Container(
        // Phase 18: Restore rounded capsule background after re-reading
        // Function PDF page 9 — MX Player DOES have a dark capsule behind
        // the speed slider (Phase 17 was wrong to remove it).
        margin: const EdgeInsets.only(top: 40),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.black75,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Speed labels
            SizedBox(
              width: totalWidth,
              child: Row(
                children: SpeedSlider._speeds
                    .asMap()
                    .entries
                    .map(
                      (e) => SizedBox(
                        width: slotWidth,
                        child: Text(
                          '${_fmtSpeed(e.value)}x',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: e.key == selectedIdx
                                ? AppColors.accentBlue
                                : Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 8),

            // Track + draggable thumb (with key for bounds reporting)
            _SpeedTrack(
              key: _trackKey,
              totalWidth: totalWidth,
              slotWidth: slotWidth,
              speedCount: SpeedSlider._speeds.length,
              selectedIndex: selectedIdx,
              onIndexChanged: (idx) =>
                  widget.onSpeedChanged(SpeedSlider._speeds[idx]),
            ),

            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.fast_forward,
                  color: AppColors.accentBlue,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  '${_fmtSpeed(widget.currentSpeed)}x Speed Playing',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeedTrack extends StatelessWidget {
  final double totalWidth;
  final double slotWidth;
  final int speedCount;
  final int selectedIndex;
  final ValueChanged<int> onIndexChanged;

  const _SpeedTrack({
    super.key,
    required this.totalWidth,
    required this.slotWidth,
    required this.speedCount,
    required this.selectedIndex,
    required this.onIndexChanged,
  });

  void _handleDx(double dx) {
    var idx = (dx / slotWidth).floor();
    if (idx < 0) idx = 0;
    if (idx >= speedCount) idx = speedCount - 1;
    if (idx != selectedIndex) onIndexChanged(idx);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: totalWidth,
      height: 28,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _handleDx(d.localPosition.dx),
        onPanUpdate: (d) => _handleDx(d.localPosition.dx),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: 2,
              margin: const EdgeInsets.symmetric(horizontal: 24),
              color: Colors.white24,
            ),
            Row(
              children: List.generate(speedCount, (_) {
                return SizedBox(
                  width: slotWidth,
                  child: const Center(
                    child: SizedBox(
                      width: 6,
                      height: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
            Positioned(
              left: selectedIndex * slotWidth + slotWidth / 2 - 8,
              child: Container(
                width: 16,
                height: 16,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accentBlue,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accentBlue40,
                      blurRadius: 8,
                      spreadRadius: 1,
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
