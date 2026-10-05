import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/core/services/video_player/subtitle_look.dart';
import 'package:innocent/features/player/presentation/aspect_ratio_mode.dart';
import 'package:innocent/features/player/presentation/gestures/subtitle_band.dart';
import 'package:innocent/features/player/presentation/subtitles/player_subtitles.dart';
import 'package:innocent/features/player/presentation/video_geometry.dart';
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

/// A phone on its side, with a 16:9 film in [mode] and a two-line subtitle
/// in the app's default look — what the player draws, minus libmpv.
const _land = Phone('land', Size(915, 412), ratio: 2.625, top: 0, bottom: 0);

Widget _modeShot(AspectRatioMode mode) => Builder(builder: (context) {
      final view = MediaQuery.sizeOf(context);
      const film = Size(1920, 1080);
      final scale = screenModeScale(
          mode: mode,
          view: view,
          video: film,
          devicePixelRatio: 2.625,
          customScale: 1.4);
      final pic = pictureRect(
          view,
          pictureSize(mode: mode, view: view, video: film, scale: scale),
          Offset.zero);
      // The app's baseline look (media_kit_player_service.dart).
      final look = const SubtitleLook()
          .apply('sub-border-size', '1.5')
          .apply('sub-shadow-offset', '1');
      final g = subtitleGeometry(view: view, picture: pic, look: look);
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          Positioned.fromRect(
            rect: pic,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.amber, width: 3),
                gradient: LinearGradient(colors: [
                  Colors.blueGrey.shade600,
                  Colors.teal.shade700,
                ]),
              ),
            ),
          ),
          Positioned(
            left: g.box.left,
            width: g.box.width,
            bottom: view.height - g.bottom,
            child: SubtitleText(
                'ဘယ်သူမှ မသိခဲ့ကြဘူး\nNobody knew where it went.',
                look: look,
                geometry: g),
          ),
          GestureValueText(
              value: mode.labelIn(AppStrings.of(context)), valueSize: 26),
        ]),
      );
    });

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
  for (final m in AspectRatioMode.values) {
    screens('screen_mode_${m.name}', () => _modeShot(m), phones: const [_land]);
  }
}
