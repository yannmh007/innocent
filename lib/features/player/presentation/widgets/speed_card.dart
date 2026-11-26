import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// The playback speed, as MX Player 3.4.3 shows it when its "1X" shortcut
/// is tapped (the owner, 26 Nov 2026: "every shortcut as MX's"; reference
/// lab run 45862946745): the controls go, and a card rises at the foot of
/// the picture — − [1.00x ✎] + over a slider from 0.25x to 4.0x, dots at
/// every half, the whole numbers named under it, and a reset at its end. A
/// tap above the card puts it away. MX's measures on the owner's phone
/// sideways: 610 x 115 dp, centred, 17 dp off the bottom; ± 32 dp; the
/// value's pill 128 x 43; the slider 517 dp. MX's proportions and kinds of
/// control, Innocent's colours: the card on the shade's black (60 %, the
/// same see-through as MX's), the pill on [PlayerUi.surface], the slider in
/// the accent. Before, the shortcut stepped through five speeds with a
/// toast.
class SpeedCard extends StatelessWidget {
  const SpeedCard({
    super.key,
    required this.speed,
    required this.onSpeed,
    required this.onEdit,
    required this.onDismiss,
  });

  final double speed;
  final ValueChanged<double> onSpeed;

  /// The pill's ✎: type a speed (CustomSpeedDialog).
  final VoidCallback onEdit;
  final VoidCallback onDismiss;

  static const double min = 0.25;
  static const double max = 4.0;
  static const double step = 0.05;

  /// The card's black: the shade's within a panel (MX's card read 102 of
  /// 255 over a white frame, as its panels do).
  static const Color _ground = Color(0x99000000);

  double _snap(double v) =>
      ((v.clamp(min, max) / step).round() * step).clamp(min, max).toDouble();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final s = AppStrings.of(context);
    final width = (size.width - 32).clamp(0.0, 610.0);
    return Stack(
      children: [
        // Above the card: a tap puts it away (MX's fl_touch).
        Positioned.fill(
          child: Semantics(
            label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
            child: GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 17 + pad.bottom,
          child: Center(
            child: SizedBox(
              width: width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _ground,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(shadows: PlayerUi.shadeInk),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            _Round(
                              icon: Icons.remove_rounded,
                              tooltip: s.pwDecrease(s.playbackSpeed),
                              onTap: () => onSpeed(_snap(speed - step)),
                            ),
                            const Spacer(),
                            _Pill(value: speed, onTap: onEdit),
                            const Spacer(),
                            _Round(
                              icon: Icons.add_rounded,
                              tooltip: s.pwIncrease(s.playbackSpeed),
                              onTap: () => onSpeed(_snap(speed + step)),
                            ),
                            // Over the reset's column, as MX's +.
                            const SizedBox(width: 26),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: _Scale(
                                value: speed.clamp(min, max).toDouble(),
                                onChanged: (v) => onSpeed(_snap(v)),
                              ),
                            ),
                            IconButton(
                              tooltip: s.reset,
                              onPressed: () => onSpeed(1.0),
                              icon: const Icon(Icons.restart_alt_rounded,
                                  size: 24, color: PlayerUi.textPrimary,
                                  shadows: PlayerUi.shadeInk),
                              constraints: const BoxConstraints(
                                  minWidth: 34, minHeight: 40),
                              padding: EdgeInsets.zero,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// − or + : a 32 dp tonal disc, as MX's.
class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      // A 48 dp target round a 32 dp disc.
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      padding: EdgeInsets.zero,
      icon: Container(
        width: 32,
        height: 32,
        decoration: const BoxDecoration(
          color: PlayerUi.raised,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 20, color: PlayerUi.textPrimary),
      ),
    );
  }
}

/// The value in its pill with a ✎: a tap types a speed.
class _Pill extends StatelessWidget {
  const _Pill({required this.value, required this.onTap});

  final double value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          // MX's is 128 wide; 120 keeps a 320 dp phone held upright clear.
          constraints: const BoxConstraints(minWidth: 120, minHeight: 43),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: PlayerUi.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${value.toStringAsFixed(2)}x',
                style: const TextStyle(
                  color: PlayerUi.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.edit_rounded,
                  size: 18, color: PlayerUi.textPrimary),
            ],
          ),
        ),
      ),
    );
  }
}

/// The slider with MX's marks: a dot at every half from 0.5 to 3.5, and
/// 0.25x, 1.0x, 2.0x, 3.0x, 4.0x named under it.
class _Scale extends StatelessWidget {
  const _Scale({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  static const double _inset = 12; // the thumb's overlay radius: the track's ends

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final track = c.maxWidth - 2 * _inset;
      double x(double v) =>
          _inset + (v - SpeedCard.min) / (SpeedCard.max - SpeedCard.min) * track;
      const labelStyle = TextStyle(
        color: PlayerUi.textPrimary,
        fontSize: 12,
        shadows: PlayerUi.shadeInk,
      );
      return SizedBox(
        height: 30 + 22,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var v = 0.5; v <= 3.5 + 1e-9; v += 0.5)
              Positioned(
                left: x(v) - 2,
                top: 13,
                child: const SizedBox(
                  width: 4,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: PlayerUi.textSecondary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 30,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  activeTrackColor: PlayerUi.accent,
                  inactiveTrackColor: const Color(0x66FFFFFF),
                  thumbColor: PlayerUi.accent,
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: _inset),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                  trackShape: const RectangularSliderTrackShape(),
                ),
                child: Slider(
                  value: value,
                  min: SpeedCard.min,
                  max: SpeedCard.max,
                  divisions: ((SpeedCard.max - SpeedCard.min) / SpeedCard.step)
                      .round(),
                  onChanged: onChanged,
                ),
              ),
            ),
            for (final v in const [0.25, 1.0, 2.0, 3.0, 4.0])
              Positioned(
                left: x(v) - 22,
                width: 44,
                top: 30,
                child: Text(
                  v == 0.25 ? '0.25x' : '${v.toStringAsFixed(1)}x',
                  textAlign: TextAlign.center,
                  style: labelStyle,
                ),
              ),
          ],
        ),
      );
    });
  }
}
