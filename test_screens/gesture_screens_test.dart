import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/widgets/brightness_indicator.dart';
import 'package:innocent/features/player/presentation/widgets/gesture_hud.dart';
import 'package:innocent/features/player/presentation/widgets/gestures_help_overlay.dart';
import 'package:innocent/features/player/presentation/widgets/volume_indicator.dart';

import 'harness.dart';

/// The player's gesture feedback, drawn over a stand-in frame the way
/// player_screen.dart stacks it (the player itself needs libmpv).
Widget _over(Widget Function(BuildContext) layer) => Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                Colors.blueGrey.shade700,
                Colors.brown.shade400,
              ]),
            ),
          ),
        ),
        Builder(builder: layer),
      ]),
    );

void main() {
  setUpAll(loadScreenFonts);
  const one = [large];

  screens('gestures_help', () => const GesturesHelpOverlay(),
      phones: one, scrolls: 2);
  screens('gesture_volume_boost',
      () => _over((_) => const VolumeIndicator(value: 1.6)),
      phones: one);
  screens('gesture_brightness',
      () => _over((_) => const BrightnessIndicator(value: 0.7)),
      phones: one);
  screens(
      'gesture_speed',
      () => _over((c) =>
          GestureValueText(value: '1.5x', caption: AppStrings.of(c).scSpeed)),
      phones: one);
  screens(
      'gesture_stack',
      () => _over((_) => const Positioned.fill(
          child: DoubleTapRippleView(
              ripple: DoubleTapRipple(forward: true, seconds: 30, serial: 3)))),
      phones: one);
}
