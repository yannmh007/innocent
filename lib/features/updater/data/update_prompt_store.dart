import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the update prompt and the update notification have to remember
/// between launches: which version the user already declined, when they were
/// last asked, when the manifest was last read, and when the notification
/// last went out for which version.
///
/// LAST ASKED AND LAST READ ARE DIFFERENT FACTS. One throttles interruptions,
/// the other throttles requests, and they are spent at different moments — see
/// [lastCheckedAt].
///
/// ONE STORE, not two. Step 6's notification obeys the same per-version
/// dismissal as step 5's dialog — a version the user declined must not come
/// back as a notice — and splitting that fact across two stores is how the two
/// surfaces would eventually disagree about it.
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

  /// When the manifest was last read SUCCESSFULLY, as milliseconds since
  /// epoch. Distinct from [_lastShownKey] — see [lastCheckedAt].
  static const String _lastCheckedKey = 'updater_last_checked_ms';

  /// The version code the notification was last posted for. Step 6.
  static const String _notifiedVersionKey = 'updater_notified_version';

  /// When that notification went out, as milliseconds since epoch.
  static const String _notifiedAtKey = 'updater_notified_at_ms';

  /// Whether POST_NOTIFICATIONS has already been asked for once, in context.
  static const String _permissionAskedKey = 'updater_notification_asked';

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

  /// When the app last got an answer out of the manifest, or null.
  ///
  /// NOT the same question as [lastShownAt], and conflating the two was a real
  /// bug. The shown-time is written only when a dialog appears, so a user with
  /// nothing to update never wrote anything and re-fetched the manifest on
  /// every resume — thirty times a day for the state almost everyone is in
  /// almost all the time. §3's first rule is "check at most once every 24
  /// hours", and it is about requests.
  Future<DateTime?> lastCheckedAt() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final ms = sp.getInt(_lastCheckedKey);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.lastCheckedAt: $e');
      return null;
    }
  }

  /// Record that the manifest answered at [at].
  ///
  /// Written on SUCCESS ONLY. A timeout or a 500 means the app still does not
  /// know what the latest release is, and silencing the checker for a day over
  /// one bad moment would be the opposite of the point — a user who was
  /// offline at breakfast should not have to wait until tomorrow to be told
  /// about a release. Failures cost a fast local error, not a download.
  Future<void> recordChecked(DateTime at) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_lastCheckedKey, at.millisecondsSinceEpoch);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.recordChecked: $e');
    }
  }

  /// The version the notification last went out for, or null.
  Future<int?> notifiedVersionCode() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getInt(_notifiedVersionKey);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.notifiedVersion: $e');
      return null;
    }
  }

  /// When the notification last went out, or null.
  Future<DateTime?> lastNotifiedAt() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final ms = sp.getInt(_notifiedAtKey);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.lastNotifiedAt: $e');
      return null;
    }
  }

  /// Record that the notice for [versionCode] was posted at [at].
  ///
  /// Written flat, NOT as a maximum like [recordDismissed]. The two are
  /// answering different questions: a dismissal is a standing answer that must
  /// never be walked back, while this is "what is currently in the shade", and
  /// if the manifest moves to a different build that is genuinely the new
  /// truth — including a rollback, which should be allowed to notify.
  Future<void> recordNotified(int versionCode, DateTime at) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_notifiedVersionKey, versionCode);
      await sp.setInt(_notifiedAtKey, at.millisecondsSinceEpoch);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.recordNotified: $e');
    }
  }

  /// Whether POST_NOTIFICATIONS has been asked for already.
  ///
  /// Android stops showing the system dialog after two refusals and simply
  /// returns "denied" forever after. Asking once, in context, and then never
  /// again is both what the platform rewards and what step 6 requires: the
  /// in-app dialog still covers the user, so a second ask buys nothing and
  /// costs the goodwill of the first.
  Future<bool> notificationPermissionAsked() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_permissionAskedKey) ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.permissionAsked: $e');
      // On a store that will not open, claim it HAS been asked. The cost of
      // being wrong that way is one missing notification; the other way it is
      // a permission dialog on every single tap.
      return true;
    }
  }

  Future<void> recordNotificationPermissionAsked() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_permissionAskedKey, true);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdatePromptStore.recordAsked: $e');
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
