import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Centralised haptic feedback. Adds tactile confirmation to:
/// - Long-press start (gesture initiation)
/// - Lock toggle
/// - Bookmark add
/// - PiP entry
/// - Favourite toggle
class HapticService {
  /// Subtle tap — for routine confirmations
  static Future<void> light() async {
    try {
      await HapticFeedback.lightImpact();
    } catch (e) { if (kDebugMode) debugPrint('haptic_service.best-effort: $e'); }
  }

  /// Medium impact — for state changes (lock, toggle)
  static Future<void> medium() async {
    try {
      await HapticFeedback.mediumImpact();
    } catch (e) { if (kDebugMode) debugPrint('haptic_service.best-effort: $e'); }
  }

  /// Selection click — for stepper/slider changes
  static Future<void> selection() async {
    try {
      await HapticFeedback.selectionClick();
    } catch (e) { if (kDebugMode) debugPrint('haptic_service.best-effort: $e'); }
  }
}
