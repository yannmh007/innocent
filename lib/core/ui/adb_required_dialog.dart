import 'package:flutter/material.dart';

import '../services/adb/adb_service.dart';
import '../theme/app_colors.dart';
import '../../features/settings/presentation/adb_connect_screen.dart';

/// The one place Innocent asks the user to connect ADB before showing content
/// that lives in Android/data or Android/obb.
///
/// Those folders are readable only through an ADB connection — for most people
/// that means the iADB app, whose always-on server keeps the link alive. Rather
/// than each screen inventing its own wording (and its own dead end when the
/// connection has dropped), every entry point routes through here so the
/// explanation, the tone and the one-tap path to the ADB screen are identical
/// everywhere.
///
/// Returns true when the user came back from the ADB screen — the caller should
/// then retry whatever the user was trying to open.
class AdbRequiredDialog {
  const AdbRequiredDialog._();

  /// Show the prompt. [what] names the thing being opened, so the message reads
  /// naturally: "this folder", "this video", "hidden folders".
  static Future<bool> show(
    BuildContext context, {
    String what = 'this folder',
  }) async {
    // Ask the backend what it can tell us, so the copy matches reality: is the
    // iADB app even installed, or just not connected right now?
    var installed = false;
    try {
      installed = await AdbService.instance.iadbInstalledAndRunning();
    } catch (_) {
      // Treat any failure as "not installed" — the dialog still works.
    }
    if (!context.mounted) return false;

    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: AppColors.accentBlue.withOpacity(0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(
                installed ? Icons.link_off : Icons.lock_outline,
                color: AppColors.accentBlue,
                size: 28,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              installed ? 'Reconnect to view $what' : 'Locked folder',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              installed
                  ? 'The connection to iADB has dropped, so $what can\u2019t be '
                      'read right now. Reconnecting takes one tap and usually '
                      'holds from then on.'
                  : 'Android keeps app-data folders private, so $what can only '
                      'be opened through an ADB connection. The iADB app '
                      'handles that once and then stays connected.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.white70,
                fontSize: 13.5,
                height: 1.55,
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(dctx).pop(false),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    foregroundColor: AppColors.white55,
                  ),
                  child: const Text('Not now'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(dctx).pop(true),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(installed ? 'Reconnect' : 'Set up'),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (go != true || !context.mounted) return false;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const AdbConnectScreen()),
    );
    // The caller decides what to retry; report that the user has been given a
    // chance to connect.
    return context.mounted;
  }

  /// True when Innocent can currently read Android/data — i.e. the selected
  /// backend has a live connection. Never throws.
  static Future<bool> isConnected() async {
    try {
      final backend = await AdbService.instance.getBackend();
      if (backend == 'iadb') {
        return await AdbService.instance.iadbConnected();
      }
      return await AdbService.instance.isConnected();
    } catch (_) {
      return false;
    }
  }

  /// Convenience used by every entry point: if the connection is live, do
  /// nothing and return true; otherwise show the prompt and report whether the
  /// caller should retry.
  static Future<bool> ensureConnected(
    BuildContext context, {
    String what = 'this folder',
  }) async {
    if (await isConnected()) return true;
    if (!context.mounted) return false;
    return show(context, what: what);
  }
}
