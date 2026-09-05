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

  @override
  Future<void> setVolume(double value) async {
    try {
      final clamped = value.clamp(0.0, 1.0);
      await FlutterVolumeController.setVolume(clamped);
    } catch (_) {
      // Silently fail
    }
  }
}
