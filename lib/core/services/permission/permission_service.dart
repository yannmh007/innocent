import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Permission service abstraction
abstract class PermissionService {
  Future<bool> hasVideoPermission();
  Future<bool> requestVideoPermission();

  /// Whether the user has selected "Don't ask again" / disabled the
  /// permission in system settings, leaving the in-app request UI
  /// unable to make further progress. The only path forward is for
  /// the user to enable it themselves in Android Settings — call
  /// [openSystemSettings] to deep-link there.
  Future<bool> isVideoPermissionPermanentlyDenied();

  /// Open the system app-settings page for this app so the user can
  /// flip the relevant permission back on. Returns true if the
  /// settings UI was opened (always true on Android in normal cases).
  Future<bool> openSystemSettings();

  /// Audit: "All files access" (MANAGE_EXTERNAL_STORAGE on Android 11+).
  /// Opt-in only. Lets the user point the library at folders outside
  /// the scoped-storage roots. The OS routes the request through a
  /// dedicated system screen rather than the regular permission
  /// dialog, so this method opens that screen and the caller polls
  /// [hasFullStorageAccess] when the user comes back.
  Future<bool> hasFullStorageAccess();
  Future<void> requestFullStorageAccess();

  /// POST_NOTIFICATIONS (Android 13+). Required or a foreground-service
  /// notification is silently suppressed from the shade — which is exactly what
  /// breaks the "pair from the notification" flow. On < 33 this is always true.
  Future<bool> hasNotificationPermission();

  /// Request POST_NOTIFICATIONS. Returns true if granted (or not needed on the
  /// running Android version).
  Future<bool> requestNotificationPermission();

  /// Whether the user has permanently denied notifications (so only a trip to
  /// system settings can re-enable them).
  Future<bool> isNotificationPermanentlyDenied();
}

class PermissionServiceImpl implements PermissionService {
  @override
  Future<bool> hasVideoPermission() async {
    if (!Platform.isAndroid) return true;
    final sdk = await _androidSdk();
    if (sdk >= 33) {
      return await Permission.videos.isGranted;
    } else {
      return await Permission.storage.isGranted;
    }
  }

  @override
  Future<bool> requestVideoPermission() async {
    if (!Platform.isAndroid) return true;
    final sdk = await _androidSdk();
    if (sdk >= 33) {
      final video = await Permission.videos.request();
      final audio = await Permission.audio.request();
      return video.isGranted || audio.isGranted;
    } else {
      final storage = await Permission.storage.request();
      return storage.isGranted;
    }
  }

  @override
  Future<bool> isVideoPermissionPermanentlyDenied() async {
    if (!Platform.isAndroid) return false;
    final sdk = await _androidSdk();
    // On API 33+ videos+audio replaced the old READ_EXTERNAL_STORAGE.
    // We treat "permanently denied" as the state where the system
    // dialog will no longer appear — i.e., the user picked "Don't
    // ask again" at least once. permission_handler exposes this
    // directly via `isPermanentlyDenied`.
    if (sdk >= 33) {
      final v = await Permission.videos.isPermanentlyDenied;
      final a = await Permission.audio.isPermanentlyDenied;
      return v || a;
    } else {
      return await Permission.storage.isPermanentlyDenied;
    }
  }

  @override
  Future<bool> openSystemSettings() async {
    try {
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> hasFullStorageAccess() async {
    if (!Platform.isAndroid) return false;
    final sdk = await _androidSdk();
    // MANAGE_EXTERNAL_STORAGE is only meaningful from API 30 onward;
    // older Androids already grant broad storage via the legacy
    // READ_EXTERNAL_STORAGE permission.
    if (sdk < 30) return true;
    try {
      return await Permission.manageExternalStorage.isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> requestFullStorageAccess() async {
    if (!Platform.isAndroid) return;
    final sdk = await _androidSdk();
    if (sdk < 30) return;
    try {
      // permission_handler routes manageExternalStorage to the
      // system "All files access" Settings screen — it does NOT
      // show a regular permission dialog. The user grants by
      // flipping a switch and tapping back to return.
      await Permission.manageExternalStorage.request();
    } catch (_) {
      // Some OEM ROMs do not expose the All-files-access screen.
      // In that case the call throws; we ignore and let the user
      // fall back to scoped storage.
    }
  }

  Future<int> _androidSdk() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt;
    } catch (_) {
      return 33; // Assume modern by default
    }
  }

  @override
  Future<bool> hasNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    final sdk = await _androidSdk();
    // POST_NOTIFICATIONS is a runtime permission only from API 33 (Android 13).
    // Below that, notifications are allowed by default.
    if (sdk < 33) return true;
    try {
      return await Permission.notification.isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    final sdk = await _androidSdk();
    if (sdk < 33) return true;
    try {
      final status = await Permission.notification.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isNotificationPermanentlyDenied() async {
    if (!Platform.isAndroid) return false;
    final sdk = await _androidSdk();
    if (sdk < 33) return false;
    try {
      return await Permission.notification.isPermanentlyDenied;
    } catch (_) {
      return false;
    }
  }
}
