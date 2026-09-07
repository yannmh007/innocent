import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/services/permission/permission_service.dart';

/// The quiet "an update is available" notice. Step 6 of
/// `docs/updater_plan.md`, §4A.
///
/// Thin over the platform, exactly like `TransferForegroundService`: the same
/// `mx_clone/transfer_service` channel, the same try/catch on every call, the
/// same rule that a notification is an enhancement and never a dependency. The
/// native side (`UpdateNotification.kt`) posts it on its OWN notification
/// channel so a user can mute update notices without muting the progress bar
/// of a transfer in flight.
///
/// THE PERMISSION IS CHECKED HERE AND NEVER REQUESTED HERE. On Android 13+
/// POST_NOTIFICATIONS is a runtime permission; without it `notify()` is a
/// silent no-op at the platform level, so calling anyway would be harmless but
/// dishonest — [show] would report success for a notice nobody can see.
/// Asking for it is a separate, deliberate act that belongs to a screen the
/// user is looking at (see `AppUpdateScreen`), never to a background check on
/// resume. Step 6's rule: do not crash, do not nag; the step 5 dialog still
/// covers the user.
class UpdateNotificationService {
  const UpdateNotificationService({
    PermissionService? permissions,
  }) : _permissions = permissions;

  final PermissionService? _permissions;

  /// The channel `TransferForegroundService` and the install service already
  /// talk to. One native seam for the updater, not three.
  static const MethodChannel _channel =
      MethodChannel('mx_clone/transfer_service');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  PermissionService get _perms => _permissions ?? PermissionServiceImpl();

  /// Post the notice. Returns true only if it actually reached the shade.
  ///
  /// [title] and [text] are resolved by the caller, which has a
  /// `BuildContext` and therefore a locale. Nothing here knows what language
  /// the user reads.
  Future<bool> show({required String title, required String text}) async {
    if (!_supported) return false;

    // Silence, not a request and not an error. §6's first rows: a version
    // check that cannot reach the user is not worth interrupting them over.
    if (!await _hasPermission()) return false;

    try {
      final ok = await _channel.invokeMethod<bool>(
        'showUpdateNotification',
        <String, dynamic>{'title': title, 'text': text},
      );
      return ok ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('UpdateNotificationService.show: $e');
      return false;
    }
  }

  /// Take the notice down.
  ///
  /// No permission check: cancelling a notification that was never posted is
  /// free, and a user who revoked notifications after one went out still
  /// deserves to have it cleared.
  Future<void> cancel() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('cancelUpdateNotification');
    } catch (e) {
      if (kDebugMode) debugPrint('UpdateNotificationService.cancel: $e');
    }
  }

  Future<bool> _hasPermission() async {
    try {
      return await _perms.hasNotificationPermission();
    } catch (e) {
      if (kDebugMode) debugPrint('UpdateNotificationService.perm: $e');
      return false;
    }
  }
}
