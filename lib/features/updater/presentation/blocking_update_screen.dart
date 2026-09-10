import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_version.dart';
import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import '../data/update_check_service.dart';
import '../domain/app_release.dart';
import '../domain/update_prompt_decision.dart';
import 'update_action_panel.dart';

/// The one screen in Innocent a user cannot leave. Step 7 of
/// `docs/updater_plan.md`, §2's "emergency brake".
///
/// Shown ONLY when [UpdatePromptDecision.isBlocked] says so, which means only
/// when the installed build is below a `min_supported` the server stated
/// clearly AND there is a downloadable release at or above it. Every other
/// state in the world — no network, a malformed row, a zero, a minimum higher
/// than anything published — is not blocked, and this screen never appears.
///
/// IT BLOCKS THE APP, NOT THE UPDATER. The whole download-and-install flow
/// from steps 3 and 4 is right here, as the same [UpdateActionPanel] the
/// Settings screen renders. A screen that refused to let the user leave AND
/// gave them no way to fix it would not be a brake; it would be a brick.
///
/// IT LETS GO BY ITSELF. If the row that caused this is corrected — the wrong
/// number was typed, the release was pulled — the screen has to notice without
/// the user doing anything, because they cannot reach anything else. So it
/// re-checks on every resume and on demand, and it releases on ANY answer that
/// is not a clear, current block, a failed check included. A person whose
/// connection has dropped must never be trapped here.
///
/// Nothing downloads or installs on its own. §7: no silent install, ever. The
/// user taps Update, and confirms again in Android's own installer.
class BlockingUpdateScreen extends ConsumerStatefulWidget {
  const BlockingUpdateScreen({super.key, required this.release});

  /// The release that caused the block, and the one being offered.
  final AppRelease release;

  /// True while this screen is on screen anywhere.
  ///
  /// Guards against a second push. The check that shows this runs on every
  /// resume, and stacking two identical un-poppable screens would take two
  /// programmatic pops to clear — one of which nothing would ever issue.
  static bool get isShowing => _showing;
  static bool _showing = false;

  /// Put it up, once.
  static Future<void> show(BuildContext context, AppRelease release) async {
    if (_showing) return;
    _showing = true;
    try {
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => BlockingUpdateScreen(release: release),
          // No route below it is reachable by gesture, and it is not a dialog:
          // fullscreenDialog would give it a close affordance, which is the
          // one thing it must not have.
          settings: const RouteSettings(name: '/update-required'),
        ),
      );
    } finally {
      _showing = false;
    }
  }

  @override
  ConsumerState<BlockingUpdateScreen> createState() =>
      _BlockingUpdateScreenState();
}

class _BlockingUpdateScreenState extends ConsumerState<BlockingUpdateScreen>
    with WidgetsBindingObserver {
  late AppRelease _release = widget.release;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have gone to Settings, or the row may have been corrected
    // while they were away. This is the only check that can still run — the
    // shell's own is skipped while this screen is the current route — so it is
    // the only way out that does not involve installing.
    if (state == AppLifecycleState.resumed) _recheck();
  }

  /// Re-read the manifest and let go unless it still clearly says block.
  ///
  /// FAILS OPEN, AND THAT IS THE POINT. A timeout, a 500, a malformed row and
  /// a corrected row all end the same way: the screen goes. Being wrong in
  /// this direction costs one unenforced update; being wrong in the other
  /// costs someone their app with no way to reach the thing that would fix it.
  Future<void> _recheck() async {
    if (_checking || !mounted) return;
    setState(() => _checking = true);

    AppRelease? latest;
    try {
      latest = await const UpdateCheckService().fetchLatest();
    } catch (_) {
      latest = null;
    }

    if (!mounted) return;

    final stillBlocked = UpdatePromptDecision.isBlocked(
      release: latest,
      installedBuild: AppVersion.build,
    );

    if (!stillBlocked) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _release = latest!;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final notes = _release.notesFor(
      Localizations.localeOf(context).languageCode,
    );

    // canPop: false is what makes this a block. It stops the system back
    // gesture and the back button; it does NOT stop the programmatic pop in
    // _recheck, which is exactly the asymmetry wanted — the app decides when
    // this ends, and it decides by re-reading the manifest.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.darkBackground,
        body: SafeArea(
          child: TabletConstrainedWidth(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 40, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.system_update,
                    size: 44,
                    color: Colors.orangeAccent,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    s.updateRequired,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    s.updateRequiredBody,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 22),
                  _row(s.updateInstalledVersion, AppVersion.full),
                  _row(s.updateLatestVersion, _release.headline),
                  if (notes != null && notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      notes.trim(),
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                  const SizedBox(height: 26),
                  // Steps 3-4, the same widget the Settings screen renders.
                  // Nothing starts on its own: the user taps Download, then
                  // Install, then confirms in Android's own dialog.
                  UpdateActionPanel(release: _release),
                  const SizedBox(height: 22),
                  // THE ESCAPE HATCH, and it is not decoration. If the number
                  // that caused this was typed by mistake, this is how someone
                  // gets out the moment it is corrected, without waiting for a
                  // resume and without installing anything.
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _checking ? null : _recheck,
                      icon: const Icon(Icons.refresh),
                      label: Text(
                        _checking ? s.updateChecking : s.updateCheckNow,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
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
