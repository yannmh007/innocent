import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/di/core_providers.dart';
import '../../../core/router/routes.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/cache/media_prewarm_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/adb_required_dialog.dart';
import '../../settings/presentation/adb_connect_screen.dart';
import '../../user_data/user_data_providers.dart';
import '../../../core/app_version.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../domain/folder.dart';
import '../domain/new_badge.dart';
import '../domain/sort_options.dart';
import '../domain/video.dart';
import 'folder_list_item.dart';
import 'grid_tiles.dart';
import 'library_provider.dart';
import 'search_app_bar.dart';
import 'sort_view_dialog.dart';
import 'video_list_item.dart';
import 'widgets/continue_watching.dart';
import 'selection_provider.dart';
import 'widgets/quick_access_chips.dart';
import 'widgets/recent_search_chips.dart';
import 'widgets/recently_added.dart';
import 'widgets/resume_fab.dart';
import 'widgets/folder_selection_action_bar.dart';
import 'widgets/selection_action_bar.dart';
import 'widgets/selection_app_bar.dart';
import 'widgets/folder_selection_app_bar.dart';
import 'widgets/video_option_menu.dart';
import '../../../core/utils/async_value_extensions.dart';

/// Local tab — shows folders/videos with view mode, sort, search
class LocalScreen extends ConsumerStatefulWidget {
  const LocalScreen({super.key});

  @override
  ConsumerState<LocalScreen> createState() => _LocalScreenState();
}

class _LocalScreenState extends ConsumerState<LocalScreen> {
  bool _permissionChecked = false;
  bool _hasPermission = false;
  bool _permanentlyDenied = false;
  bool _searchActive = false;
  late final FabScrollVisibility _fabVisibility;
  bool _crashRecoveryChecked = false;
  // Continue Watching is hidden by default; long-pressing the Resume FAB
  // reveals it, and any navigation (opening a folder, another activity) or a
  // search hides it again — see _hideContinueWatching. This mirrors how a
  // quick-peek shelf works in polished players: on demand, not permanent.
  bool _showContinueWatching = false;

  @override
  void initState() {
    super.initState();
    _fabVisibility = FabScrollVisibility();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Leaving the tab before the first frame completes disposes this State;
      // both helpers below touch `ref` and `context`, which throws after that.
      if (!mounted) return;
      _checkPermission();
      // Audit: crash-recovery one-shot. If the app was force-closed
      // (or OOM-killed) mid-playback, ResumeStorage still holds the
      // marker — offer a snackbar with "Resume" so the user can
      // continue with one tap. A clean exit cleared the marker, so
      // most starts find nothing to recover and skip silently.
      _checkCrashRecovery();
    });
  }

  Future<void> _checkCrashRecovery() async {
    if (_crashRecoveryChecked) return;
    _crashRecoveryChecked = true;
    try {
      final last = await ref.read(resumeStorageProvider).getLastPlaying();
      if (last == null) return;
      if (!mounted) return;
      // The prompt names the video, on the public Local tab, seconds after the
      // app opens — so it has to honour the same hiding the lists do. A video
      // binned or vaulted since it was last played would otherwise announce
      // its own title to whoever opened the app next, which is precisely what
      // hiding it was for. Clear the marker rather than just skipping, or it
      // waits and does the same thing on the next cold start.
      final binned = ref.read(recycleBinProvider).any(
            (e) => normalizeMediaUri(e.videoUri) == normalizeMediaUri(last.uri),
          );
      if (binned || last.uri.contains('private_vault')) {
        await ref.read(resumeStorageProvider).clearLastPlaying();
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            AppStrings.of(context).resumePromptFor(last.title),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          action: SnackBarAction(
            label: AppStrings.of(context).resume,
            onPressed: () {
              if (!mounted) return;
              context.push(
                Routes.player,
                extra: {'uri': last.uri, 'title': last.title},
              );
            },
          ),
        ),
      );
      // Clear the marker either way — we've offered once; we don't
      // pester. If the user dismisses without tapping RESUME they
      // can always re-open from history.
      await ref.read(resumeStorageProvider).clearLastPlaying();
    } catch (_) {
      // Recovery is best-effort. A failure here must never block
      // the home screen from rendering.
    }
  }

  @override
  void dispose() {
    _fabVisibility.dispose();
    super.dispose();
  }

  Future<void> _checkPermission() async {
    final svc = ref.read(permissionServiceProvider);
    var has = await svc.hasVideoPermission();
    var permaDenied = false;
    if (!has) {
      has = await svc.requestVideoPermission();
      // Audit: if the system did not grant after our request, check
      // whether the user has flipped "Don't ask again". In that
      // state the system dialog will never appear again from inside
      // the app, so we must show a different UI that deep-links
      // into system settings.
      if (!has) {
        permaDenied = await svc.isVideoPermissionPermanentlyDenied();
      }
    }
    if (mounted) {
      setState(() {
        _permissionChecked = true;
        _hasPermission = has;
        _permanentlyDenied = permaDenied;
      });
    }
    // Permission is settled — quietly warm the folder (and then music)
    // caches in the background so the first folder the user opens, and the
    // Music tab, load instantly instead of showing a spinner. Throttled +
    // pauses while backgrounded, so it won't heat the device.
    if (has) {
      ref.read(mediaPrewarmProvider).start();
    }
  }

  void _showSortSheet() {
    SortViewDialog.show(context);
  }

  /// Phase 45 (audit): handle taps in the AppBar overflow menu. Items
  /// match MX Player V3's `menu/list.xml`: Refresh / Settings / Help /
  /// About. Help opens an in-app dialog because we don't have an
  /// online help site to link out to.
  Future<void> _onAppBarMenu(BuildContext context, String value) async {
    switch (value) {
      case 'refresh':
        // Invalidate the library providers to force a re-scan of the
        // device's media — and, when iADB is connected, re-scan Android/data
        // too so hidden app-cache videos refresh at the same time. MX Player's
        // "Media scan" does the device half; this adds the ADB half.
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppStrings.of(context).refreshingLibrary),
              duration: const Duration(milliseconds: 1200),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        final res = await refreshLibraryWithAdb(ref);
        if (mounted && res == LibraryRefreshResult.adbDisconnected) {
          _showAdbReconnectHint();
        }
        break;
      case 'settings':
        if (context.mounted) {
          // rootNavigator:true → push above the shell so the bottom tab bar is
          // hidden (Settings is a full-screen sub-feature). Without it the tab
          // bar stays visible and tapping Music/Transfer/Me would leave the
          // Settings page sitting on top. Matches the Me tab.
          Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute(
              builder: (_) => const SettingsScreen(),
            ),
          );
        }
        break;
      case 'help':
        await _showHelpDialog(context);
        break;
      case 'about':
        await _showAboutDialog(context);
        break;
    }
  }

  /// Phase 45 (audit): Help dialog with FAQ + bug report entry points.
  /// MX Player V3 has a full Help submenu; we condense it into a single
  /// dialog because the linked external pages don't exist for us.
  Future<void> _showHelpDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dctx) => SimpleDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).help,
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        children: [
          // Phase 45 (audit refined): MX Player V3 Help submenu has:
          // What's new / Features / FAQ / Version check / Send bug
          // report / Privacy help / About. We replicate each as a
          // SimpleDialogOption matching the decompiled
          // menu_navigation_drawer.xml structure.
          _HelpItem(
            icon: Icons.fiber_new_outlined,
            label: AppStrings.of(context).whatsNew,
            onTap: () {
              Navigator.of(dctx).pop();
              _showWhatsNewDialog(context);
            },
          ),
          _HelpItem(
            icon: Icons.featured_play_list_outlined,
            label: AppStrings.of(context).features,
            onTap: () {
              Navigator.of(dctx).pop();
              _showFeaturesDialog(context);
            },
          ),
          _HelpItem(
            icon: Icons.quiz_outlined,
            label: AppStrings.of(context).faq,
            onTap: () {
              Navigator.of(dctx).pop();
              _showFaqDialog(context);
            },
          ),
          _HelpItem(
            icon: Icons.new_releases_outlined,
            label: AppStrings.of(context).versionCheck,
            onTap: () {
              Navigator.of(dctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(AppStrings.of(context)
                      .latestVersion(AppVersion.full)),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
          _HelpItem(
            icon: Icons.bug_report_outlined,
            label: AppStrings.of(context).sendBugReport,
            onTap: () {
              Navigator.of(dctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(AppStrings.of(context).bugReportHint),
                  duration: const Duration(seconds: 3),
                ),
              );
            },
          ),
          _HelpItem(
            icon: Icons.privacy_tip_outlined,
            label: AppStrings.of(context).privacy,
            onTap: () {
              Navigator.of(dctx).pop();
              _showPrivacyDialog(context);
            },
          ),
        ],
      ),
    );
  }

  /// Phase 45 (audit refined): What's new dialog — release notes for
  /// the current build.
  Future<void> _showWhatsNewDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: const Text("What's new",
            style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              const Text(
                'Build 60 — Phase 45 audit refinements',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 12),
              Text(
                '• Help submenu (What\'s new / Features / FAQ / Version / Bug report / Privacy)\n'
                '• Audio effects: Bass Boost / Virtualizer / Reverb (7 presets)\n'
                '• Resume "Use by default" checkbox\n'
                '• DecoderType 4-mode (Default / HW / HW+ / SW)\n'
                '• Music sort system (Title/Album/Artist/Date/Duration/Size/Path)\n'
                '• "Properties" dialog with File name + Format fields\n'
                '• 15 advanced preferences wired (audio delay, sub charset, etc.)\n'
                '• Brightness reset on player close\n'
                '• Folder scroll position preserved',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(AppStrings.of(context).close,
                style: TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
  }

  Future<void> _showFeaturesDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).features,
            style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(AppStrings.of(context).featuresIntro,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(AppStrings.of(context).featuresBody,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(AppStrings.of(context).close,
                style: TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
  }

  Future<void> _showFaqDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).faq,
            style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(AppStrings.of(context).faqQ1,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(AppStrings.of(context).faqA1,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              Text(AppStrings.of(context).faqQ2,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(AppStrings.of(context).faqA2,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              Text(AppStrings.of(context).faqQ3,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(AppStrings.of(context).faqA3,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              Text(AppStrings.of(context).faqQ4,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(AppStrings.of(context).faqA4,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(AppStrings.of(context).close,
                style: TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
  }

  Future<void> _showPrivacyDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).privacy,
            style: TextStyle(color: Colors.white)),
        content: Text(AppStrings.of(context).privacyBody,
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(AppStrings.of(context).close,
                style: TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
  }

  /// Phase 45 (audit): About dialog showing version + credits.
  Future<void> _showAboutDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).appName,
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppStrings.of(context).versionOf(AppVersion.full),
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Text(AppStrings.of(context).aboutBody,
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(AppStrings.of(context).ok,
              style: TextStyle(color: AppColors.accentBlue),
            ),
          ),
        ],
      ),
    );
  }

  IconData _viewModeIcon(ViewMode mode) {
    switch (mode) {
      case ViewMode.allFolders:
        return Icons.folder_copy_outlined;
      case ViewMode.files:
        return Icons.description_outlined;
      case ViewMode.folders:
        return Icons.folder_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(libraryPreferencesProvider);
    final notifier = ref.read(libraryPreferencesProvider.notifier);

    final folderSelActive = ref.watch(folderSelectionProvider).isNotEmpty;
    final videoSelActive = ref.watch(selectionProvider).isNotEmpty;
    final selectionActive = folderSelActive || videoSelActive;

    return PopScope(
      // When a selection is active, the back gesture should exit selection
      // mode rather than leaving the Local tab (matches MX Player and every
      // premium gallery). Only when nothing is selected does back behave
      // normally.
      canPop: !selectionActive,
      onPopInvoked: (didPop) {
        if (!didPop) {
          if (folderSelActive) {
            ref.read(folderSelectionProvider.notifier).clear();
          }
          if (videoSelActive) {
            ref.read(selectionProvider.notifier).clear();
          }
        }
      },
      child: Scaffold(
      backgroundColor: AppColors.specScaffold,
      appBar: ref.watch(folderSelectionProvider).isNotEmpty
          ? const FolderSelectionAppBar()
          : ref.watch(selectionProvider).isNotEmpty
          ? SelectionAppBar(
              totalVisible: ref.watch(filteredAllVideosProvider).maybeWhen(
                    data: (list) => list.length,
                    orElse: () => 0,
                  ),
            )
          : _searchActive
          ? (SearchAppBar(
              onClose: () => setState(() => _searchActive = false),
            ) as PreferredSizeWidget)
          : AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              title: Text(
                prefs.viewMode == ViewMode.files ? 'Videos' : 'Folders',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              actions: [
                IconButton(
                  icon: Icon(_viewModeIcon(prefs.viewMode)),
                  tooltip: 'View mode: ${prefs.viewMode.label}',
                  onPressed: notifier.cycleViewMode,
                ),
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: 'Search',
                  onPressed: () => setState(() {
                    _searchActive = true;
                    _showContinueWatching = false;
                  }),
                ),
                IconButton(
                  // Phase 16: MX Player uses a layout-grid icon, not tune
                  icon: const Icon(Icons.dashboard_outlined),
                  tooltip: 'Sort & view',
                  onPressed: _showSortSheet,
                ),
                // Phase 45 (audit): MX Player V3 has a 3-dot overflow menu
                // with Refresh, Settings, Help submenu, Quit. We replicate
                // it exactly (verified against decompiled menu/list.xml).
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'More',
                  color: AppColors.darkSurface,
                  onSelected: (v) => _onAppBarMenu(context, v),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'refresh',
                      child: Row(children: [
                        const Icon(Icons.refresh,
                            size: 20, color: Colors.white70),
                        const SizedBox(width: 12),
                        Text(AppStrings.of(context).refresh,
                            style: const TextStyle(color: Colors.white)),
                      ]),
                    ),
                    PopupMenuItem(
                      value: 'settings',
                      child: Row(children: [
                        const Icon(Icons.settings_outlined,
                            size: 20, color: Colors.white70),
                        const SizedBox(width: 12),
                        Text(AppStrings.of(context).settingsTitle,
                            style: const TextStyle(color: Colors.white)),
                      ]),
                    ),
                    PopupMenuItem(
                      value: 'help',
                      child: Row(children: [
                        const Icon(Icons.help_outline,
                            size: 20, color: Colors.white70),
                        const SizedBox(width: 12),
                        Text(AppStrings.of(context).help,
                            style: const TextStyle(color: Colors.white)),
                      ]),
                    ),
                    PopupMenuItem(
                      value: 'about',
                      child: Row(children: [
                        const Icon(Icons.info_outline,
                            size: 20, color: Colors.white70),
                        const SizedBox(width: 12),
                        Text(AppStrings.of(context).about,
                            style: const TextStyle(color: Colors.white)),
                      ]),
                    ),
                  ],
                ),
              ],
            ),
      body: !_permissionChecked
          ? const Center(child: CircularProgressIndicator())
          : !_hasPermission
              ? _buildPermissionDenied()
              : Stack(
                  children: [
                    Column(
                      children: [
                        if (_searchActive &&
                            ref.watch(searchQueryProvider).isEmpty)
                          RecentSearchChips(
                            onTap: (query) {
                              ref.read(searchQueryProvider.notifier).state =
                                  query;
                            },
                          ),
                        Expanded(child: _buildContent(prefs.viewMode)),
                      ],
                    ),
                    // Phase 34: MX has a floating "Magic Pen" FAB on the
                    // right edge above the Resume FAB. Verified frame 1.
                  ],
                ),
      // Floating Resume play button (hide on scroll-up, show on scroll-down).
      // MX-Player-style placement: anchored low toward the bottom-right
      // corner (small lift above the nav bar), not floating mid-screen.
      // Settings → List → "Floating button". The switch had no reader, so the
      // Resume button was always there. People who never use it — or who find
      // it covering the last row of a grid — now have the option the settings
      // screen already promised them.
      // The selection actions live down here, not in the AppBar. Seven icons
      // do not fit in an AppBar on a phone, and the ones that overflowed were
      // simply invisible — Delete among them.
      bottomNavigationBar: videoSelActive
          ? const SelectionActionBar()
          : folderSelActive
              ? const FolderSelectionActionBar()
              : null,
      floatingActionButton: videoSelActive ||
              folderSelActive ||
              !_hasPermission ||
              _searchActive ||
              !ref
                  .watch(playerSettingsProvider)
                  .get(PlayerSetting.listFloatingButton)
          ? null
          : Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ResumeFab(
                visibilityListenable: _fabVisibility.visible,
                onLongPress: _toggleContinueWatching,
              ),
            ),
    ),
    );
  }

  Widget _buildPermissionDenied() {
    // Audit: split into two states.
    //
    // First-ask: the user just hasn't granted yet. Button calls
    // [_checkPermission] which re-runs the system dialog flow.
    //
    // Permanently denied: the user has tapped "Don't ask again" (or
    // disabled the permission in Settings). The in-app request is a
    // dead end — the system will silently return denied without
    // showing a dialog. The only way out is for the user to flip the
    // permission in system settings, so we deep-link there.
    final body = _permanentlyDenied
        ? AppStrings.of(context).permissionRationalePermanent
        : AppStrings.of(context).permissionRationale;
    final buttonLabel = _permanentlyDenied
        ? AppStrings.of(context).permissionOpenSettings
        : AppStrings.of(context).permissionGrant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.accentBlue15,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.folder_special_outlined,
                size: 48,
                color: AppColors.accentBlue,
              ),
            ),
            const SizedBox(height: 24),
            Text(AppStrings.of(context).findYourVideos,
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.darkOnSurfaceMuted,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              onPressed: () async {
                if (_permanentlyDenied) {
                  // Deep-link into the app-settings page. When the
                  // user returns (didChangeAppLifecycleState fires
                  // on resume) we'll re-check; for now we also
                  // re-check immediately in case the user toggled
                  // the permission and is bouncing back without
                  // triggering lifecycle.
                  await ref
                      .read(permissionServiceProvider)
                      .openSystemSettings();
                  if (mounted) await _checkPermission();
                } else {
                  await _checkPermission();
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                buttonLabel,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(ViewMode viewMode) {
    // For "Files" view, flatten all videos across folders
    if (viewMode == ViewMode.files) {
      return _buildAllVideosList();
    }
    return _buildFolderList();
  }

  Widget _buildFolderList() {
    final foldersAsync = ref.watch(filteredFoldersProvider);
    final prefs = ref.watch(libraryPreferencesProvider);

    return foldersAsync.whenOrFallback(
      data: (folders) {
        if (folders.isEmpty) {
          final query = ref.read(searchQueryProvider);
          return Center(
            child: Text(
              query.isNotEmpty
                  ? 'No folders match "$query"'
                  : 'No video folders found',
              style: const TextStyle(color: AppColors.darkOnSurfaceMuted),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            final res = await refreshLibraryWithAdb(ref);
            if (mounted && res == LibraryRefreshResult.adbDisconnected) {
              _showAdbReconnectHint();
            }
          },
          // Responsive: LIST mode caps content at a readable width and
          // centres it on tablets/laptops; GRID mode keeps full width so
          // its responsive column count (3–5) fills the larger screen.
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: prefs.layout == LayoutMode.grid
                    ? double.infinity
                    : 640,
              ),
              child: CustomScrollView(
                controller: _fabVisibility.controller,
                slivers: [
                  // Phase 17: Quick-access chips shown in BOTH list and grid modes
                  // (MX Player V3 t=2 shows chips above the folder list too).
                  if (ref.watch(searchQueryProvider).isEmpty)
                    SliverToBoxAdapter(
                      child: QuickAccessChips(
                        onNavigate: _hideContinueWatching,
                      ),
                    ),
                  // Continue Watching carousel: hidden by default, revealed by
                  // long-pressing the Resume FAB, and only while search is empty.
                  if (_showContinueWatching &&
                      ref.watch(searchQueryProvider).isEmpty)
                    const SliverToBoxAdapter(child: ContinueWatchingSection()),
                  if (ref.watch(searchQueryProvider).isEmpty)
                    const SliverToBoxAdapter(child: RecentlyAddedSection()),
                  if (prefs.layout == LayoutMode.grid)
                    SliverPadding(
                      // innocent_folders_grid_spec: 120 dp column pitch
                      // (→ 3 columns at 360 dp, more on tablets/laptops),
                      // 95 dp row pitch. Thumbnails are centred inside each
                      // cell so the side margins land at ~29 dp on phones.
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 120,
                          mainAxisExtent: 95,
                          crossAxisSpacing: 0,
                          mainAxisSpacing: 0,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final selectedFolders =
                                ref.watch(folderSelectionProvider);
                            return FolderGridTile(
                              folder: folders[i],
                              selectionMode: selectedFolders.isNotEmpty,
                              selected: selectedFolders
                                  .contains(folders[i].path),
                              onTap: () => _openFolder(folders[i]),
                              onLongPress: () {
                                HapticFeedback.selectionClick();
                                ref
                                    .read(folderSelectionProvider.notifier)
                                    .toggle(folders[i].path);
                              },
                            );
                          },
                          childCount: folders.length,
                        ),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: folders.length,
                      itemBuilder: (context, i) => _buildFolderItem(folders[i]),
                    ),
                ],
              ),
            ),
          ),
        );
      },
      loading: () => Center(
        // Phase 44: tell the user what's happening on a cold scan so they
        // don't think the app is hung. The spinner is fast enough on
        // subsequent launches that this only shows on the very first one.
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(AppStrings.of(context).scanningVideos,
              style: const TextStyle(
                color: AppColors.darkOnSurfaceMuted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(AppStrings.of(context).errorLoadingFoldersPrefix + ': $e',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.error),
          ),
        ),
      ),
    );
  }

  Widget _buildFolderItem(Folder folder) {
    final selectedFolders = ref.watch(folderSelectionProvider);
    final selectionMode = selectedFolders.isNotEmpty;
    return FolderListItem(
      folder: folder,
      selectionMode: selectionMode,
      selected: selectedFolders.contains(folder.path),
      onTap: () => _openFolder(folder),
      onLongPress: () {
        HapticFeedback.selectionClick();
        ref.read(folderSelectionProvider.notifier).toggle(folder.path);
      },
    );
  }

  /// Long-press the Resume FAB toggles the Continue Watching strip. If there's
  /// no watch history the strip renders nothing, so we still flip the flag (the
  /// section itself no-ops) rather than second-guessing here.
  void _toggleContinueWatching() {
    if (!mounted) return;
    final willShow = !_showContinueWatching;
    if (willShow) {
      // If there's nothing in progress, the strip would render empty — tell the
      // user instead of silently doing nothing, so the long-press feels
      // responsive rather than broken.
      final inProgress = ref.read(publicHistoryProvider).any(
            (e) => e.progress > 0.05 && e.progress < 0.95,
          );
      if (!inProgress) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(AppStrings.of(context).noContinueWatching),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        return;
      }
    }
    setState(() => _showContinueWatching = willShow);
    // Scroll to the top so the just-revealed strip is actually in view (it sits
    // above the folder/video list).
    if (_showContinueWatching && _fabVisibility.controller.hasClients) {
      _fabVisibility.controller.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  /// Hide the Continue Watching strip. Called on any navigation away from the
  /// list (opening a folder, launching another activity) so it behaves like a
  /// momentary peek, not a persistent section.
  void _hideContinueWatching() {
    if (_showContinueWatching && mounted) {
      setState(() => _showContinueWatching = false);
    }
  }

  /// Shown after a refresh when iADB was expected but the connection had
  /// dropped. Non-blocking: the existing app-data videos stay visible; this
  /// just offers a one-tap way back to reconnect.
  void _showAdbReconnectHint() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text(
          'iADB is disconnected — app-data videos may be out of date. '
          'Reconnect to refresh them.',
        ),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'Reconnect',
          onPressed: () {
            if (mounted) {
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(builder: (_) => const AdbConnectScreen()),
              );
            }
          },
        ),
      ),
    );
  }

  /// Open a video in the player. For Android/data videos read over ADB
  /// (adb:// uri), the connection must be live first — otherwise the player
  /// opens and immediately fails with "playback failed". So we route those
  /// through the same one-tap ADB prompt used for folders: if the user isn't
  /// connected they get the dialog (with a path straight to the ADB screen)
  /// instead of a broken player. Regular on-device videos open directly.
  Future<void> _openVideo(Video video) async {
    _hideContinueWatching();
    if (video.uri.startsWith('adb://')) {
      final ok = await AdbRequiredDialog.ensureConnected(
        context,
        what: 'this video',
      );
      if (!ok || !mounted) return;
      // Re-check: ensureConnected returns true both when already connected and
      // when the user has just visited the ADB screen. Only proceed to the
      // player if we're actually connected now, so a user who opened the ADB
      // screen but didn't connect doesn't still hit a failed player.
      if (!await AdbRequiredDialog.isConnected() || !mounted) return;
    }
    if (!mounted) return;
    context.push(
      Routes.player,
      extra: {'uri': video.uri, 'title': video.title},
    );
  }

  Future<void> _openFolder(Folder folder) async {
    // Opening a folder is a navigation away from the list — collapse the
    // Continue Watching peek so it doesn't linger behind the new screen.
    _hideContinueWatching();
    // Android/data and Android/obb folders are only readable while an ADB
    // connection is live. Opening one after the connection dropped used to give
    // an empty folder with no explanation; now the user gets one prompt and a
    // single tap through to the ADB screen, then lands in the folder.
    if (_isAdbBackedFolder(folder)) {
      final ok = await AdbRequiredDialog.ensureConnected(
        context,
        what: 'this folder',
      );
      if (!ok || !mounted) return;
    }
    if (!mounted) return;
    // Pass path + name as query parameters. Using Uri(...).toString() lets
    // Dart encode arbitrary UTF-8 (emoji, Thai, Burmese, a literal '%',
    // etc.) correctly and exactly once, so any folder name opens reliably.
    // (The previous approach encoded the path INTO a path segment, which
    // broke go_router's matching for special-character names.)
    final location = Uri(
      path: Routes.folderDetail,
      queryParameters: {
        'path': folder.path,
        'name': folder.name,
      },
    ).toString();
    if (!mounted) return;
    context.push(location);
  }

  /// True for folders whose contents can only be read over ADB/iADB.
  bool _isAdbBackedFolder(Folder folder) {
    final cover = folder.coverThumbnailPath ?? '';
    if (cover.startsWith('adb://')) return true;
    return folder.path.contains('/Android/data/') ||
        folder.path.contains('/Android/obb/');
  }

  /// "Files" view — true flat list of all videos across folders
  Widget _buildAllVideosList() {
    final videosAsync = ref.watch(filteredAllVideosProvider);
    final prefs = ref.watch(libraryPreferencesProvider);

    return videosAsync.whenOrFallback(
      data: (videos) {
        if (videos.isEmpty) {
          final query = ref.read(searchQueryProvider);
          return Center(
            child: Text(
              query.isNotEmpty
                  ? '${AppStrings.of(context).noVideosMatch} "$query"'
                  : AppStrings.of(context).noVideosFound,
              style: const TextStyle(color: AppColors.darkOnSurfaceMuted),
            ),
          );
        }
        final now = DateTime.now();
        // MX Player's documented rule, applied in one place — see
        // NewBadge: "Copied or modified files within 7 days, which have no
        // playback record", with the period configurable 0-90 (0 = off).
        final newPeriodDays = ref
            .watch(extraSettingsProvider)
            .getInt(IntSetting.newTaggedPeriod);
        // The other half of MX Player's rule: the tag is for files with no
        // playback record. Without this the badge survived being watched and
        // sat there for the rest of the week.
        final playedUris = ref.watch(playedUrisProvider);
        Widget body;
        if (prefs.layout == LayoutMode.grid) {
          body = GridView.builder(
            controller: _fabVisibility.controller,
            // innocent_videos_grid_spec: 16 dp side margins, 18 dp gutter,
            // 155-wide 16:9 thumbs → 2 columns at 360 dp, scaling to more
            // columns on tablets/laptops at the same thumbnail width.
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisSpacing: 0,
              crossAxisSpacing: 18,
              childAspectRatio: 1.13,
            ),
            itemCount: videos.length,
            itemBuilder: (_, i) {
              final video = videos[i];
              final isNew = NewBadge.applies(
                video: video,
                periodDays: newPeriodDays,
                playedUris: playedUris,
                normalize: normalizeMediaUri,
                now: now,
              );
              return VideoGridTile(
              key: ValueKey(video.uri),
                video: video,
                showNewBadge: isNew,
                onTap: () => _openVideo(video),
                onMoreTap: () => VideoOptionMenu.show(context, video),
                onLongPress: () =>
                    ref.read(selectionProvider.notifier).toggle(video.uri),
              );
            },
          );
        } else {
          body = ListView.builder(
            controller: _fabVisibility.controller,
            itemCount: videos.length,
            itemBuilder: (_, i) {
              final video = videos[i];
              final isNew = NewBadge.applies(
                video: video,
                periodDays: newPeriodDays,
                playedUris: playedUris,
                normalize: normalizeMediaUri,
                now: now,
              );
              return VideoListItem(
              key: ValueKey(video.uri),
                video: video,
                showNewBadge: isNew,
                onTap: () => _openVideo(video),
                onMoreTap: () => VideoOptionMenu.show(context, video),
                // Phase 13: Long-press starts selection mode
                onLongPress: () =>
                    ref.read(selectionProvider.notifier).toggle(video.uri),
              );
            },
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            final res = await refreshLibraryWithAdb(ref);
            if (mounted && res == LibraryRefreshResult.adbDisconnected) {
              _showAdbReconnectHint();
            }
          },
          child: body,
        );
      },
      loading: () => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(AppStrings.of(context).scanningVideos,
              style: const TextStyle(
                color: AppColors.darkOnSurfaceMuted,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
      error: (e, _) => Center(
        child: Text(AppStrings.of(context).errorWord + ': $e',
            style: const TextStyle(color: AppColors.error)),
      ),
    );
  }
}

/// Phase 45 (audit refined): row in the Help SimpleDialog. Each row
/// has a leading icon + label and a tap target sized for thumb use.
/// Matches MX Player V3's Help submenu visual rhythm.
class _HelpItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _HelpItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SimpleDialogOption(
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Colors.white70),
            const SizedBox(width: 16),
            Text(label, style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
