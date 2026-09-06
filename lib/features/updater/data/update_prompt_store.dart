import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The two facts the update prompt has to remember between launches:
/// which version the user already declined, and when they were last asked.
///
/// `shared_preferences` because it is already a dependency and this is two
/// scalars. Every read fails soft — a preferences store that will not open is
/// a reason to behave as if nothing was ever dismissed, not a reason to break
/// the app's resume path.
class UpdatePromptStore {
  const UpdatePromptStore();

  /// The highest version code the user has said "Not now" to.
  static const String _dismissedKey = 'updater_prompt_dismissed_version';

  /// When the prompt was last actually shown, as milliseconds since epoch.
  static const String _lastShownKey = 'updater_prompt_last_shown_ms';

  Future<int?> dismissedVersionCode() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getInt(_dismissedKey);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.dismissed: $e');
      return null;
    }
  }

  Future<DateTime?> lastShownAt() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final ms = sp.getInt(_lastShownKey);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.lastShown: $e');
      return null;
    }
  }

  /// Recorded when the dialog goes UP, not when it is answered.
  ///
  /// A prompt the user swiped away without reading still cost them an
  /// interruption, and the 24-hour clock is about interruptions.
  Future<void> recordShown(DateTime at) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_lastShownKey, at.millisecondsSinceEpoch);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.recordShown: $e');
    }
  }

  /// "Not now" for [versionCode].
  ///
  /// Written as a MAXIMUM, never blindly overwritten: if a later build was
  /// already declined, recording an older one would un-silence it. The
  /// decision compares with `<=`, so lowering this value would bring a
  /// dismissed prompt back.
  Future<void> recordDismissed(int versionCode) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final existing = sp.getInt(_dismissedKey);
      if (existing != null && existing >= versionCode) return;
      await sp.setInt(_dismissedKey, versionCode);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.recordDismissed: $e');
    }
  }
}
