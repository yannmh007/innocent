import 'package:flutter_volume_controller/flutter_volume_controller.dart';

/// Volume service abstraction
abstract class VolumeService {
  /// Get current volume (0.0 - 1.0)
  Future<double> getVolume();

  /// Set volume (0.0 - 1.0)
  Future<void> setVolume(double value);
}

class VolumeServiceImpl implements VolumeService {
  @override
  Future<double> getVolume() async {
    try {
      final v = await FlutterVolumeController.getVolume();
      return v ?? 0.5;
    } catch (_) {
      return 0.5;
    }
  }

  /// The plugin shows Android's own volume panel on every change unless
  /// told otherwise. The player's swipe draws its own bar (as MX does);
  /// the system panel on top of it covered the picture and the gesture.
  /// The hardware volume keys are not affected: Android shows its panel
  /// for those whatever this says.
  static bool _systemUiOff = false;

  @override
  Future<void> setVolume(double value) async {
    try {
      final clamped = value.clamp(0.0, 1.0);
      if (!_systemUiOff) {
        await FlutterVolumeController.updateShowSystemUI(false);
        _systemUiOff = true;
      }
      await FlutterVolumeController.setVolume(clamped);
    } catch (_) {
      // Silently fail
    }
  }
}
