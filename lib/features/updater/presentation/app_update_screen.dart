import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_version.dart';
import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import '../data/update_check_service.dart';
import '../data/update_download_controller.dart';
import '../data/update_download_service.dart';
import '../data/update_install_service.dart';
import '../domain/app_release.dart';

/// Settings → App update. Steps 2-3 of `docs/updater_plan.md`.
///
/// CHECK, DOWNLOAD, THEN HAND OVER. It reads the manifest, fetches and
/// verifies the APK, and offers Install. It never installs anything itself:
/// Install fires the system package installer and the user confirms there.
/// A silent install is impossible without device-owner privileges and an app
/// that tried would be indistinguishable from malware — §7 rules it out.
///
/// The download button appears only when [AppRelease.canDownload] is true —
/// `apk_url` and `apk_sha256` are nullable and are null in the row today, so
/// this screen must be safe to ship before any APK has ever been published.
///
/// THE SCREEN DOES NOT OWN THE DOWNLOAD. It reads
/// [updateDownloadProvider] and renders whatever that says. The download
/// itself lives in [UpdateDownloadNotifier], above the widget tree, so it
/// survives this route being popped — and so that reopening the screen
/// mid-download shows the LIVE progress bar rather than a Download button
/// that would start a second writer on the same `.part`.
///
/// NEVER HIDDEN, even when up to date. "You're on the latest version" is a
/// useful thing to be able to confirm, and this screen is where someone comes
/// when they suspect the app is stale — including after dismissing a prompt,
/// which is the whole reason it exists.
class AppUpdateScreen extends ConsumerStatefulWidget {
  const AppUpdateScreen({super.key});

  @override
  ConsumerState<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends ConsumerState<AppUpdateScreen> {
  bool _loading = true;
  AppRelease? _release;
  UpdateCheckFailure? _failure;

  /// True while the pre-install re-hash runs. Local to this screen on purpose:
  /// unlike a download, it is over in a second and does not outlive the route.
  bool _installing = false;

  /// The sentence from the last install attempt, or null. §6 fixes the
  /// wording for every one of them.
  String? _installMessage;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    // A check mid-download would swap the row out from under the running
    // fetch. The controller, not this screen, is the authority on whether one
    // is running.
    if (ref.read(updateDownloadProvider).isBusy) return;
    setState(() {
      _loading = true;
      _failure = null;
    });

    AppRelease? release;
    UpdateCheckFailure? failure;
    try {
      release = await const UpdateCheckService().fetchLatest();
    } on UpdateCheckFailure catch (e) {
      failure = e;
    } catch (_) {
      // Anything unforeseen still has to leave a usable screen behind.
      failure = const UpdateCheckFailure.malformed();
    }

    if (!mounted) return;
    // A finished or failed result for a build the manifest no longer offers is
    // stale; drop it so the screen shows a plain Download button again.
    final current = ref.read(updateDownloadProvider);
    if (current.versionCode != null &&
        current.versionCode != release?.versionCode) {
      ref.read(updateDownloadProvider.notifier).reset();
    }
    setState(() {
      _release = release;
      _failure = failure;
      _loading = false;
    });
  }

  /// Ask the controller to download. Stops at "Downloaded" — see the class doc.
  ///
  /// No local state is set here and no result is awaited. Both would be a lie:
  /// this screen is one observer of a download it does not own, and the tap
  /// may well ATTACH to a fetch that was already running before the route was
  /// even built. Everything the user sees comes back through
  /// [updateDownloadProvider].
  void _download(AppRelease release) {
    // Strings are resolved here, in a widget that has a BuildContext. The
    // controller and the service deliberately have none — they outlive any
    // route — so the notification wording is handed to them, never fetched.
    final s = AppStrings.of(context);
    unawaited(ref.read(updateDownloadProvider.notifier).start(
          release,
          notificationTitle: s.updateNotificationTitle,
          notificationDone: s.updateDownloaded,
        ));
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
        // The file is gone. Put the screen back to offering a download, so
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

  /// Plain ISO-ish date. No `intl` dependency for one line of text, and a
  /// numeric date reads the same in all three locales.
  String _date(DateTime d) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    final local = d.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(s.settingsAppUpdate)),
      body: TabletConstrainedWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            _statusCard(s),
            const SizedBox(height: 16),
            _row(s.updateInstalledVersion, AppVersion.full),
            if (_release != null)
              _row(
                s.updateLatestVersion,
                '${_release!.versionName} (${_release!.versionCode})',
              ),
            if (_release?.sizeLabel != null)
              _row(s.updateSize, _release!.sizeLabel!),
            if (_release?.releasedAt != null)
              _row(s.updateReleased, _date(_release!.releasedAt!)),
            ..._downloadSection(s),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                // Disabled during a download: re-checking would replace the
                // release the download is running against.
                onPressed: _loading || _downloadIsBusy ? null : _check,
                icon: const Icon(Icons.refresh),
                label: Text(_loading ? s.updateChecking : s.updateCheckNow),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(AppStrings s) {
    if (_loading) {
      return _card(
        icon: Icons.hourglass_empty,
        colour: Colors.white70,
        title: s.updateChecking,
      );
    }

    final failure = _failure;
    if (failure != null) {
      return _card(
        icon: Icons.cloud_off,
        colour: Colors.orangeAccent,
        title: failure.kind == UpdateFailureKind.notConfigured
            ? s.updateNotConfigured
            : s.updateCheckFailed,
      );
    }

    final release = _release;
    if (release == null) {
      // The table is reachable and holds nothing. Not an error: there is
      // simply no newer build, which is the same thing the user needs to know.
      return _card(
        icon: Icons.check_circle_outline,
        colour: Colors.greenAccent,
        title: s.updateUpToDate,
      );
    }

    if (!release.isNewerThan(AppVersion.build)) {
      return _card(
        icon: Icons.check_circle_outline,
        colour: Colors.greenAccent,
        title: s.updateUpToDate,
      );
    }

    final notes = release.notesFor(
      Localizations.localeOf(context).languageCode,
    );
    return _card(
      icon: Icons.system_update,
      colour: AppColors.primaryBlue,
      title: s.updateAvailable,
      body: notes,
      // No footer any more. It used to read "Downloading arrives in the next
      // step", which was true when the screen could only check — and became a
      // contradiction the moment step 3 put a Download button directly under
      // it. Step 4 removes the last of that scaffolding.
    );
  }

  Widget _card({
    required IconData icon,
    required Color colour,
    required String title,
    String? body,
    String? footer,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colour, size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  if (body != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      body,
                      style: const TextStyle(fontSize: 14, height: 1.45),
                    ),
                  ],
                  if (footer != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      footer,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _downloadIsBusy => ref.watch(updateDownloadProvider).isBusy;

  /// The download half of the screen, rendered from the controller's state.
  ///
  /// Empty until there is genuinely something to download.
  List<Widget> _downloadSection(AppStrings s) {
    final release = _release;
    if (_loading || release == null) return const [];
    if (!release.isNewerThan(AppVersion.build)) return const [];

    // THE GATE. Both columns are nullable and both are null in the row today,
    // so this build ships with no button at all — which is why it is safe to
    // merge before any APK is published. Absent, not disabled: a button that
    // cannot ever work is worse than no button, because people keep pressing
    // it.
    if (!release.canDownload) return const [];

    final d = ref.watch(updateDownloadProvider);
    // State belonging to a different build is not this release's business.
    final mine = d.versionCode == null || d.versionCode == release.versionCode;
    final phase = mine ? d.phase : UpdateDownloadPhase.idle;

    return [
      const SizedBox(height: 24),
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

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
