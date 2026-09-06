import 'package:flutter/material.dart';

import '../../../core/app_version.dart';
import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import '../data/update_check_service.dart';
import '../data/update_download_service.dart';
import '../domain/app_release.dart';

/// Settings → App update. Steps 2-3 of `docs/updater_plan.md`.
///
/// CHECK, THEN DOWNLOAD — AND STOP THERE. It reads the manifest, and when a
/// newer build with a published APK exists it fetches and verifies it. It does
/// NOT install: handing the file to the package installer is step 4, kept
/// separate so the half that writes an APK to disk can be tested on a real
/// phone before the half that asks Android to run it.
///
/// The download button appears only when [AppRelease.canDownload] is true —
/// `apk_url` and `apk_sha256` are nullable and are null in the row today, so
/// this screen must be safe to ship before any APK has ever been published.
///
/// NEVER HIDDEN, even when up to date. "You're on the latest version" is a
/// useful thing to be able to confirm, and this screen is where someone comes
/// when they suspect the app is stale — including after dismissing a prompt,
/// which is the whole reason it exists.
class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key});

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  bool _loading = true;
  AppRelease? _release;
  UpdateCheckFailure? _failure;

  _DownloadPhase _phase = _DownloadPhase.idle;
  int _received = 0;
  int _total = 0;
  String? _downloadError;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (_phase == _DownloadPhase.running ||
        _phase == _DownloadPhase.verifying) {
      return; // A check mid-download would swap the row under the download.
    }
    setState(() {
      _loading = true;
      _failure = null;
      _phase = _DownloadPhase.idle;
      _downloadError = null;
      _received = 0;
      _total = 0;
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
    setState(() {
      _release = release;
      _failure = failure;
      _loading = false;
    });
  }

  /// Fetch and verify the APK. Stops at "Downloaded" — see the class doc.
  Future<void> _download(AppRelease release) async {
    if (_phase == _DownloadPhase.running ||
        _phase == _DownloadPhase.verifying) {
      return;
    }
    // Strings are resolved BEFORE the await. The service runs without a
    // BuildContext on purpose, and reaching for one after an await is the
    // use_build_context_synchronously bug this project promotes to a warning.
    final s = AppStrings.of(context);
    final notificationTitle = s.updateNotificationTitle;
    final notificationDone = s.updateDownloaded;

    setState(() {
      _phase = _DownloadPhase.running;
      _downloadError = null;
      _received = 0;
      _total = release.apkBytes ?? 0;
    });

    try {
      await const UpdateDownloadService().download(
        release,
        notificationTitle: notificationTitle,
        notificationDone: notificationDone,
        onProgress: (received, total, _) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
        onVerifying: () {
          if (!mounted) return;
          setState(() => _phase = _DownloadPhase.verifying);
        },
      );
      if (!mounted) return;
      setState(() => _phase = _DownloadPhase.done);
    } on UpdateDownloadFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.failed;
        _downloadError = _sentenceFor(e, s);
      });
    } catch (_) {
      // The service maps what it knows about; anything left is still a failed
      // download, and the screen owes the user a sentence either way.
      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.failed;
        _downloadError = s.updateDownloadFailed;
      });
    }
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
                onPressed: _loading || _busy ? null : _check,
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
      // Honest, and only visible in a build that predates step 3. The button
      // is absent rather than disabled: a button that cannot ever work is
      // worse than no button, because the user keeps pressing it.
      footer: s.updateDownloadNotYet,
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

  bool get _busy =>
      _phase == _DownloadPhase.running || _phase == _DownloadPhase.verifying;

  /// The download half of the screen. Empty until there is genuinely
  /// something to download.
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

    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;

    return [
      const SizedBox(height: 24),
      if (_phase == _DownloadPhase.running) ...[
        LinearProgressIndicator(value: progress),
        const SizedBox(height: 10),
        Text(
          progress == null
              ? s.updateDownloading
              : '${s.updateDownloading} '
                  '${(progress * 100).round()}%  '
                  '(${_fmtBytes(_received)} / ${_fmtBytes(_total)})',
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ] else if (_phase == _DownloadPhase.verifying) ...[
        const LinearProgressIndicator(),
        const SizedBox(height: 10),
        Text(
          s.updateVerifying,
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ] else if (_phase == _DownloadPhase.done) ...[
        Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.greenAccent, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.updateDownloaded,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Honest about where this stops. Step 4 adds the install.
                  Text(
                    s.updateDownloadedNote,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ] else ...[
        if (_downloadError != null) ...[
          Text(
            _downloadError!,
            style: const TextStyle(fontSize: 13, color: Colors.orangeAccent),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => _download(release),
            icon: const Icon(Icons.download),
            label: Text(
              _phase == _DownloadPhase.failed ? s.updateRetry : s.updateDownload,
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

/// Where the download has got to. Deliberately not merged into the check's
/// `_loading` flag: a failed CHECK and a failed DOWNLOAD are different states
/// that say different things, and collapsing them is how a screen ends up
/// telling someone their network is down when their disk is full.
enum _DownloadPhase { idle, running, verifying, done, failed }
