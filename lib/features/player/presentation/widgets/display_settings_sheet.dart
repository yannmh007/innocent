import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../video_adjust.dart';
import 'player_ui.dart';

/// Display Settings sheet — brightness, contrast, saturation, hue. The
/// picture is not dimmed behind it: the change is judged on the picture.
class DisplaySettingsSheet extends ConsumerWidget {
  const DisplaySettingsSheet({super.key});

  static Future<void> show(BuildContext context) => showPlayerSheet<void>(
        context,
        barrierColor: Colors.transparent,
        builder: (_) => const DisplaySettingsSheet(),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The picture's own adjustments (video_adjust.dart): the sliders used
    // to move numbers nothing read.
    final adjust = ref.watch(videoAdjustProvider);
    final set = ref.read(videoAdjustProvider.notifier);
    final s = AppStrings.of(context);
    final pad = PlayerUi.pad(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerSheetHeader(
          title: s.displaySettingsTitle,
          divider: false,
          // An icon: beside "ပြသမှု Settings" the word took half the row,
          // and on a small phone both were cut ("ပြသမှု Setti…").
          trailing: IconButton(
            tooltip: s.reset,
            onPressed:
                adjust.isNeutral ? null : () => set.state = const VideoAdjust(),
            icon: const Icon(Icons.restart_alt_rounded, size: 22),
            color: PlayerUi.accent,
            disabledColor: PlayerUi.textDisabled,
          ),
        ),
        // Sideways the default 9/16 of the screen held two of the four
        // sliders; the rest were cut off with nothing to scroll.
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AdjustRow(
                  label: s.pwBrightness,
                  value: adjust.brightness,
                  icon: Icons.brightness_6_outlined,
                  onChanged: (v) =>
                      set.state = set.state.copyWith(brightness: v),
                ),
                _AdjustRow(
                  label: s.pwContrast,
                  value: adjust.contrast,
                  icon: Icons.contrast_rounded,
                  onChanged: (v) => set.state = set.state.copyWith(contrast: v),
                ),
                _AdjustRow(
                  label: s.pwSaturation,
                  value: adjust.saturation,
                  icon: Icons.water_drop_outlined,
                  onChanged: (v) =>
                      set.state = set.state.copyWith(saturation: v),
                ),
                _AdjustRow(
                  label: s.pwHue,
                  value: adjust.hue,
                  icon: Icons.palette_outlined,
                  onChanged: (v) => set.state = set.state.copyWith(hue: v),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One adjustment: its name and value on a line, the slider the whole
/// width under it. The name had 72 dp beside the slider, and a Burmese one
/// ("အရောင် အားကောင်းမှု") ran to three lines.
class _AdjustRow extends StatelessWidget {
  const _AdjustRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.onChanged,
  });

  final String label;
  final double value;
  final IconData icon;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final n = (value * 100).round();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Icon(icon, color: PlayerUi.textSecondary, size: 20),
                const SizedBox(width: 12),
                Expanded(child: Text(label, style: PlayerUi.rowTitle)),
                Text(
                  n > 0 ? '+$n' : '$n',
                  style: TextStyle(
                    color: n == 0 ? PlayerUi.textSecondary : PlayerUi.accent,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: PlayerUi.accent,
              inactiveTrackColor: const Color(0x33FFFFFF),
              thumbColor: Colors.white,
              overlayColor: PlayerUi.accent.withValues(alpha: 0.16),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: value,
              min: -1.0,
              max: 1.0,
              label: label,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
