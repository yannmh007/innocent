import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_version.dart';
import '../../../core/localization/app_strings.dart';
import '../../../core/services/permission/permission_service.dart';
import '../../../core/theme/app_colors.dart';
import '../data/update_download_controller.dart';
import '../data/update_download_service.dart';
import '../data/update_install_service.dart';
import '../data/update_prompt_store.dart';
import '../domain/app_release.dart';

/// Download, verify, install — steps 3 and 4, as one widget.
///
/// EXTRACTED RATHER THAN COPIED, and that is the point. Step 7 needs a second
/// screen that can reach this flow: the blocking screen a user below
/// `min_supported` cannot leave. Duplicating the state machine into it would
/// have meant two copies of the install outcome switch, two places to keep
/// §6's fixed sentences, and one of them going stale the first time either was
/// touched. This is the same code, rendered in two frames.
///
/// It owns nothing that outlives it. The download itself lives in
/// [UpdateDownloadNotifier], above the widget tree, so this panel can be built
/// and destroyed freely — reopening either screen mid-download shows the live
/// progress bar rather than a Download button that would start a second
/// writer on the same `.part`.
///
/// Renders NOTHING when there is nothing to offer: no newer release, or a
/// release with no downloadable APK. Absent, not disabled — a button that
/// cannot ever work is worse than no button, because people keep pressing it.
class UpdateActionPanel extends ConsumerStatefulWidget {
  const UpdateActionPanel({super.key, required this.release});

  /// The release to offer. Null while a check is in flight, which renders
  /// nothing.
  final AppRelease? release;

  /// Whether this panel would render anything for [release].
  ///
  /// Exposed so a host can add its own spacing around the panel only when
  /// there is something to space. The gate itself stays here, in one place:
  /// `apk_url` and `apk_sha256` are nullable and were null in the row for the
  /// whole of steps 2-3, so a copy of this condition that fell out of step
  /// would put a button on screen that could never work.
  static bool hasSomethingToOffer(AppRelease? release) =>
      release != null &&
      release.isNewerThan(AppVersion.build) &&
      release.canDownload;

  @override
  ConsumerState<UpdateActionPanel> createState() => _UpdateActionPanelState();
}

class _UpdateActionPanelState extends ConsumerState<UpdateActionPanel> {
  /// True while the pre-install re-hash runs. Local on purpose: unlike a
  /// download, it is over in a second and does not outlive the widget.
  bool _installing = false;

  /// The sentence from the last install attempt, or null. §6 fixes the
  /// wording for every one of them.
  String? _installMessage;

  @override
  Widget build(BuildContext context) {
    final children = _downloadSection(AppStrings.of(context));
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// Ask the controller to download. Stops at "Downloaded" — see the class doc.
  ///
  /// No local state is set here and no result is awaited. Both would be a lie:
  /// this widget is one observer of a download it does not own, and the tap
  /// may well ATTACH to a fetch that was already running before the route was
  /// even built. Everything the user sees comes back through
  /// [updateDownloadProvider].
  void _download(AppRelease release) {
    // Strings are resolved here, in a widget that has a BuildContext. The
    // controller and the service deliberately have none — they outlive any
    // route — so the notification wording is handed to them, never fetched.
    final s = AppStrings.of(context);
    // THE ONE PLACE POST_NOTIFICATIONS IS EVER ASKED FOR, and it is asked
    // beside the tap rather than before it: the download is about to run a
    // foreground service whose whole visible output is a progress
    // notification, so this is the moment the permission means something to
    // the person answering. Never on cold launch — a permission dialog before
    // the user has done anything is the ask most reliably refused.
    //
    // Deliberately not awaited. The download must start on the tap whatever
    // the user answers; on Android 13+ the service still runs without the
    // permission, it just has nothing to show. A notification is an
    // enhancement here, never a dependency.
    unawaited(_askForNotificationsOnce());
    unawaited(ref.read(updateDownloadProvider.notifier).start(
          release,
          notificationTitle: s.updateNotificationTitle,
          notificationDone: s.updateDownloaded,
        ));
  }

  /// Ask for POST_NOTIFICATIONS at most once in the app's lifetime.
  ///
  /// Android stops showing the dialog after two refusals and answers "denied"
  /// forever after, so a second ask is not a second chance — it is a tap the
  /// user spends for nothing. If they said no, the in-app dialog and the App
  /// update screen still tell them everything; step 6's rule is do not nag.
  Future<void> _askForNotificationsOnce() async {
    const store = UpdatePromptStore();
    try {
      final permissions = PermissionServiceImpl();
      if (await permissions.hasNotificationPermission()) return;
      if (await store.notificationPermissionAsked()) return;
      await store.recordNotificationPermissionAsked();
      await permissions.requestNotificationPermission();
    } catch (_) {
      // A permission plugin that will not answer must not take the download
      // down with it.
    }
  }

  /// Hand the verified APK to the system installer. Step 4, and the end of it.
  ///
  /// The user always taps this, and always confirms again in Android's own
  /// dialog. Nothing here installs anything by itself.
  Future<void> _install(AppRelease release, String filePath) async {
    if (_installing) return;
    final sha = release.apkSha256;
    if (sha == null) return;

    setState(() {
      _installing = true;
      _installMessage = null;
    });

    final outcome = await const UpdateInstallService().install(
      filePath: filePath,
      expectedSha256: sha,
    );

    if (!mounted) return;
    setState(() => _installing = false);
    final s = AppStrings.of(context);

    switch (outcome) {
      case UpdateInstallOutcome.handedToInstaller:
        // Android owns the screen now. Saying anything else here would be
        // guessing at what the user did next.
        break;
      case UpdateInstallOutcome.permissionNeeded:
        await _askForInstallPermission(s);
      case UpdateInstallOutcome.damaged:
        // The file is gone. Put the panel back to offering a download, so
        // Try again means something.
        ref.read(updateDownloadProvider.notifier).reset();
        setState(() => _installMessage = s.updateDownloadDamaged);
      case UpdateInstallOutcome.missing:
        ref.read(updateDownloadProvider.notifier).reset();
        setState(() => _installMessage = s.updateInstallGone);
      case UpdateInstallOutcome.signatureMismatch:
        // The signing key drifted. Retrying cannot help, so nothing is reset
        // and nothing is offered again — §6 sends them to a person.
        setState(() => _installMessage = s.updateInstallSignature);
      case UpdateInstallOutcome.noHandler:
        setState(() => _installMessage = s.updateInstallNoHandler);
    }
  }

  /// Explain, then send them to the exact Settings page — never a silent fail
  /// and never the Settings root, where the switch is four taps deep and named
  /// differently on every OEM skin.
  ///
  /// Reuses the dialog wording the Transfer feature already ships in all three
  /// locales for exactly this switch.
  Future<void> _askForInstallPermission(AppStrings s) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(
          s.allowInstallTitle,
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: Text(
          s.allowInstallBody,
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(
              s.cancel,
              style: const TextStyle(color: AppColors.white70),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(s.allowInstallAction),
          ),
        ],
      ),
    );
    if (go != true) return;
    await const UpdateInstallService().openInstallPermission();
    // No polling for the switch to flip. They come back and tap Install, and
    // it works — which is the whole contract of this path.
  }

  /// One honest line per failure. `docs/updater_plan.md` §6 fixes the wording;
  /// none of these quote a status code at the reader.
  String _sentenceFor(UpdateDownloadFailure e, AppStrings s) {
    switch (e.kind) {
      case UpdateDownloadFailureKind.damaged:
        return s.updateDownloadDamaged;
      case UpdateDownloadFailureKind.mismatch:
        return s.updateDownloadMismatch;
      case UpdateDownloadFailureKind.noSpace:
        // The two numbers, as the vault shows them.
        final needed = e.neededBytes;
        final free = e.freeBytes;
        if (needed == null || free == null) return s.updateNotEnoughSpace;
        return '${s.updateNotEnoughSpace} '
            '(${_fmtBytes(needed)} / ${_fmtBytes(free)})';
      case UpdateDownloadFailureKind.unsupported:
      case UpdateDownloadFailureKind.network:
      case UpdateDownloadFailureKind.server:
      case UpdateDownloadFailureKind.io:
        return s.updateDownloadFailed;
    }
  }

  /// Bytes already on disk, shown while waiting for the network so the wait
  /// reads as "held, nothing lost" rather than "stopped".
  String _keptLabel(AppStrings s, UpdateDownloadState d) {
    if (d.received <= 0) return s.updateWaitingForNetwork;
    return '${s.updateWaitingForNetwork} '
        '(${_fmtBytes(d.received)} ${s.updateKept})';
  }

  /// Same shape the vault's picker uses, so the two refusals read alike.
  static String _fmtBytes(int b) {
    if (b >= 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).round()} MB';
    if (b >= 1024) return '${(b / 1024).round()} KB';
    return '$b B';
  }

  /// The download half of the screen, rendered from the controller's state.
  ///
  /// Empty until there is genuinely something to download.
  List<Widget> _downloadSection(AppStrings s) {
    final release = widget.release;
    // THE GATE. Both columns are nullable and were null in the row for the
    // whole of steps 2-3, so a build could ship this with no button at all —
    // which is why it was safe to merge before any APK existed. Absent, not
    // disabled: a button that cannot ever work is worse than no button,
    // because people keep pressing it.
    if (!UpdateActionPanel.hasSomethingToOffer(release)) return const [];
    release!;

    final d = ref.watch(updateDownloadProvider);
    // State belonging to a different build is not this release's business.
    final mine = d.versionCode == null || d.versionCode == release.versionCode;
    final phase = mine ? d.phase : UpdateDownloadPhase.idle;

    return [
      if (phase == UpdateDownloadPhase.downloading) ...[
        // LIVE, and live for whoever is looking. Reopening the screen halfway
        // through a download lands here, not on a Retry button, because the
        // progress is read from the controller rather than from a field this
        // widget owned and lost when the route was popped.
        LinearProgressIndicator(value: d.fraction),
        const SizedBox(height: 10),
        Text(
          d.fraction == null
              ? s.updateDownloading
              : '${s.updateDownloading} '
                  '${(d.fraction! * 100).round()}%  '
                  '(${_fmtBytes(d.received)} / ${_fmtBytes(d.total)})',
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ] else if (phase == UpdateDownloadPhase.verifying) ...[
        const LinearProgressIndicator(),
        const SizedBox(height: 10),
        Text(
          s.updateVerifying,
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ] else if (phase == UpdateDownloadPhase.waitingForNetwork) ...[
        // Not an error, and deliberately not a Retry button. The bytes are on
        // disk, the controller is watching for the network, and it will resume
        // on its own. Retry is offered anyway for someone who would rather
        // not wait for the next probe.
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _keptLabel(s, d),
                style:
                    const TextStyle(fontSize: 13, color: Colors.orangeAccent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _download(release),
            icon: const Icon(Icons.refresh),
            label: Text(s.updateResumeNow),
          ),
        ),
      ] else if (phase == UpdateDownloadPhase.done) ...[
        Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.greenAccent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                s.updateDownloaded,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (_installMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            _installMessage!,
            style: const TextStyle(fontSize: 13, color: Colors.orangeAccent),
          ),
        ],
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            // Absent, not disabled, when there is no file path to hand over:
            // a button that cannot work is worse than no button.
            onPressed: _installing || d.filePath == null
                ? null
                : () => _install(release, d.filePath!),
            icon: const Icon(Icons.system_update_alt),
            label: Text(
              _installing ? s.updateInstallChecking : s.updateInstall,
            ),
          ),
        ),
      ] else ...[
        if (phase == UpdateDownloadPhase.failed && d.failure != null) ...[
          Text(
            _sentenceFor(d.failure!, s),
            style: const TextStyle(fontSize: 13, color: Colors.orangeAccent),
          ),
          const SizedBox(height: 12),
        ],
        // NO RETRY BUTTON FOR A MISMATCH. Every other failure here is worth
        // another attempt — the network dropped, the disk filled, the server
        // was briefly unhappy. A mismatch is not: the whole file arrived at
        // exactly the published length and the fingerprint was still wrong,
        // so the next attempt fetches the same bytes and fails on the same
        // line, having spent another ninety megabytes. Offering the button
        // would be inviting that, and on a Myanmar mobile connection the
        // invitation is expensive. Check now, below, is the action that can
        // actually change the answer: it re-reads the catalogue, and a
        // corrected record is exactly what this needs.
        if (phase != UpdateDownloadPhase.failed ||
            d.failure?.kind != UpdateDownloadFailureKind.mismatch)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              // Safe to press twice, and safe to press while a download this
              // screen never started is already running: start() attaches
              // instead of opening a second writer.
              onPressed: () => _download(release),
              icon: const Icon(Icons.download),
              label: Text(
                phase == UpdateDownloadPhase.failed
                    ? s.updateRetry
                    : s.updateDownload,
              ),
            ),
          ),
      ],
    ];
  }
}
