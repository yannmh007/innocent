import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/services/file_transfer/received_history.dart';
import 'update_download_service.dart';

/// Hands a verified APK to the system package installer. Step 4 of
/// `docs/updater_plan.md`.
///
/// NOTHING HERE INSTALLS ANYTHING. It asks Android to show the installer, and
/// the user taps Install in the system dialog. A silent install is impossible
/// without device-owner privileges and an app that tried would be
/// indistinguishable from malware — §7 rules it out explicitly.
///
/// THE INTENT PATH IS NOT NEW. `ReceivedHistoryNotifier` has handed received
/// APKs to the installer since the Transfer feature shipped, through the same
/// `FileProvider` URI and the same
/// `application/vnd.android.package-archive` MIME type, with the same
/// `canRequestPackageInstalls` gate in front of it. That path has been used on
/// real phones by real users; this reuses it rather than opening a second one
/// that would have to rediscover the same three Android quirks.
///
/// What this adds is the two checks the updater specifically needs, both of
/// them BEFORE the intent is fired:
///
///   * the SHA-256 again, because the file has been sitting on disk since the
///     download agreed with it;
///   * the signing certificate, because a key that drifted is §6's emergency
///     and the installer's own refusal says nothing useful.
class UpdateInstallService {
  const UpdateInstallService();

  /// The channel `ReceivedHistoryNotifier` already talks to. Named again here
  /// only for [_certMatchesInstalled], which is an updater-specific question
  /// and does not belong on the Transfer feature's history notifier.
  static const MethodChannel _channel =
      MethodChannel('mx_clone/transfer_service');

  /// Re-verify, then hand over.
  ///
  /// [expectedSha256] is `app_releases.apk_sha256`. Returns what happened; the
  /// screen owns the sentence, because every one of these outcomes has fixed
  /// wording in §6 and none of it belongs in a service.
  Future<UpdateInstallOutcome> install({
    required String filePath,
    required String expectedSha256,
  }) async {
    if (kIsWeb) return UpdateInstallOutcome.noHandler;

    final file = File(filePath);
    if (!await _exists(file)) return UpdateInstallOutcome.missing;

    // (2) THE SECOND VERIFICATION, and it is not redundant. The download
    // checked this file and renamed it; since then it has sat in a cache
    // directory that the OS prunes, that any file manager can reach, and that
    // another app with storage access could write to. Hashing 88 MB costs a
    // second. Handing the installer something unverified costs the user's
    // phone.
    final actual = await UpdateDownloadService.sha256OfFile(file);
    if (actual != expectedSha256) {
      // §5's rule for a complete file whose hash is wrong: it goes. Leaving it
      // would mean the next tap offers to install the same bad bytes.
      await _deleteQuietly(file);
      return UpdateInstallOutcome.damaged;
    }

    // (4) THE SIGNING-KEY EMERGENCY. Checked before the intent because
    // ACTION_VIEW reports nothing back: the user would otherwise see the
    // installer's generic "App not installed" and have no idea that the cause
    // is unrecoverable. A null answer means the platform would not say, and
    // proceeding is right — refusing on an unknown would block every
    // legitimate update on any device whose answer we cannot read.
    final certOk = await _certMatchesInstalled(filePath);
    if (certOk == false) return UpdateInstallOutcome.signatureMismatch;

    // (3) Android 8+ gates sideloading behind a per-app switch. Asked before
    // the intent so the caller can explain why, rather than dropping the user
    // on a system screen with no context — the same order the Transfer screen
    // uses.
    if (!await ReceivedHistoryNotifier.canInstallApks()) {
      return UpdateInstallOutcome.permissionNeeded;
    }

    final opened = await ReceivedHistoryNotifier.openExternally(filePath);
    return opened
        ? UpdateInstallOutcome.handedToInstaller
        : UpdateInstallOutcome.noHandler;
  }

  /// Send the user to the "install unknown apps" screen for this app.
  ///
  /// Straight there, as §6 requires — not to the general Settings root, where
  /// the switch is four taps deep and named differently on every OEM skin.
  Future<void> openInstallPermission() =>
      ReceivedHistoryNotifier.openInstallPermission();

  /// True / false / null, where null means "the platform would not say".
  Future<bool?> _certMatchesInstalled(String path) async {
    if (kIsWeb) return null;
    try {
      return await _channel.invokeMethod<bool>(
        'apkCertMatchesInstalled',
        <String, dynamic>{'path': path},
      );
    } catch (e) {
      if (kDebugMode) debugPrint('UpdateInstallService.cert: $e');
      return null;
    }
  }

  static Future<bool> _exists(File f) async {
    try {
      return await f.exists();
    } catch (_) {
      return false;
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// What happened when the user tapped Install.
///
/// One case per sentence in `docs/updater_plan.md` §6.
enum UpdateInstallOutcome {
  /// The system installer is on screen. Whether the user goes through with it
  /// is between them and Android — this app is not told, and does not ask.
  handedToInstaller,

  /// The APK is no longer on disk. The cache directory is the OS's to prune.
  missing,

  /// The file changed since the download verified it. Deleted; the screen says
  /// "Download was damaged. Try again." and offers the download again.
  damaged,

  /// "Install unknown apps" is off for this app. The screen explains in one
  /// line and offers to open that exact Settings page.
  permissionNeeded,

  /// The APK is signed by a different key from the installed app. Android
  /// would refuse the update with no override and no recovery, so this never
  /// reaches the installer. §6: "This update could not be installed. Contact
  /// support." — a genuine emergency, and the one case where the user is
  /// asked to talk to a person.
  signatureMismatch,

  /// Nothing on the phone can open an APK, or the platform is not Android.
  noHandler,
}
