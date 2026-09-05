import 'package:flutter/material.dart';

import '../../../core/app_version.dart';
import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import '../data/update_check_service.dart';
import '../domain/app_release.dart';

/// Settings → App update. Step 2 of `docs/updater_plan.md`.
///
/// CHECK ONLY. It reads the manifest and says what it found; nothing is
/// downloaded and nothing is installed. That is the point of doing it first —
/// it proves the whole server path end to end with no code that can leave a
/// half-written APK on the phone or hand a bad file to the installer.
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

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
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
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _loading ? null : _check,
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
