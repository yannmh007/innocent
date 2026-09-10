import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_version.dart';
import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import '../data/update_check_service.dart';
import '../data/update_download_controller.dart';
import '../data/update_notification_service.dart';
import '../domain/app_release.dart';
import 'update_action_panel.dart';

/// Settings → App update. Step 2 of `docs/updater_plan.md`, and the frame the
/// rest of the updater hangs in.
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

  @override
  void initState() {
    super.initState();
    _check();
    // Step 6: arriving here is the notice being acted on, however the user got
    // here — the notification itself, the dialog's Update button, or Settings.
    // Leaving it in the shade after that is the nagging §3 calls this
    // feature's real failure mode.
    unawaited(const UpdateNotificationService().cancel());
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
            // Steps 3-4, shared verbatim with the blocking screen so the
            // two can never drift. Renders nothing until there is genuinely
            // something to download.
            if (!_loading &&
                UpdateActionPanel.hasSomethingToOffer(_release)) ...[
              const SizedBox(height: 24),
              UpdateActionPanel(release: _release),
            ],
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
