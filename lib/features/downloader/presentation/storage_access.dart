import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/localization/app_strings.dart';
import '../../../core/services/permission/permission_service.dart';
import '../../../core/theme/app_colors.dart';

/// Asks once for the access Android needs to write into Downloads.
///
/// WHY THIS IS SHARED RATHER THAN COPIED: there are two ways to start a
/// download and they take completely different routes. A pasted link goes
/// through the quality sheet; a video found in the in-app browser is chosen
/// natively and enqueued straight through, never touching that sheet. The
/// prompt lived only in the sheet, so the path MOST likely to need the
/// permission was the one path that never asked — and the device reported
/// exactly that: no dialog, and files quietly landing somewhere else.
///
/// One implementation, called from both, is the only version of this that
/// cannot drift apart again.
///
/// WHY IT ALWAYS RETURNS TRUE: declining is allowed. The engine falls back to
/// a folder it can always write to, so a download never fails for want of this.
/// The prompt exists so files land where people expect them, not to hold the
/// feature hostage.
///
/// The permission itself is not an ordinary one — Android grants it only from
/// a switch in system Settings, which is why it has to be asked for out loud
/// instead of quietly requested.
Future<bool> ensureStorageAccess(BuildContext context, WidgetRef ref) async {
  try {
    final PermissionService perm = ref.read(permissionServiceProvider);
    if (await perm.hasFullStorageAccess()) return true;
    if (!context.mounted) return true;
    final AppStrings s = AppStrings.of(context);
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppColors.specSheetBg,
        title: Text(
          s.downloaderNeedsStorage,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Text(
          s.downloaderNeedsStorageBody,
          style: const TextStyle(
              color: AppColors.white70, fontSize: 13, height: 1.45),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                Text(s.cancel, style: const TextStyle(color: AppColors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              s.downloaderGrantAccess,
              style: const TextStyle(color: AppColors.primaryBlue),
            ),
          ),
        ],
      ),
    );
    if (go == true) await perm.requestFullStorageAccess();
  } catch (_) {
    // Never let asking for permission stop a download that might work anyway.
  }
  return true;
}
