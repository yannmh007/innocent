import 'package:flutter/foundation.dart';
import 'package:screen_brightness/screen_brightness.dart';

/// Brightness service abstraction
abstract class BrightnessService {
  /// Get current brightness (0.0 - 1.0)
  Future<double> getBrightness();

  /// Set brightness (0.0 - 1.0)
  Future<void> setBrightness(double value);

  /// Reset to system brightness
  Future<void> reset();
}

class BrightnessServiceImpl implements BrightnessService {
  @override
  Future<double> getBrightness() async {
    try {
      return await ScreenBrightness().current;
    } catch (_) {
      return 0.5;
    }
  }

  @override
  Future<void> setBrightness(double value) async {
    try {
      final clamped = value.clamp(0.0, 1.0);
      await ScreenBrightness().setScreenBrightness(clamped);
    } catch (_) {
      // Silently fail on unsupported platforms/devices
    }
  }

  @override
  Future<void> reset() async {
    try {
      await ScreenBrightness().resetScreenBrightness();
    } catch (e) { if (kDebugMode) debugPrint('brightness_service.best-effort: $e'); }
  }
}
