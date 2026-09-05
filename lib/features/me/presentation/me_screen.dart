import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../about/about_screen.dart';
import '../../downloader/presentation/downloader_home_screen.dart';
import '../../network_stream/presentation/network_stream_screen.dart';
import '../../../core/router/routes.dart';
import 'package:go_router/go_router.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../user_data/presentation/favourites_screen.dart';
import '../../user_data/presentation/history_screen.dart';
import '../../user_data/presentation/watch_insights_screen.dart';
import '../../user_data/presentation/playlists_screen.dart';
import '../../user_data/presentation/recycle_bin_screen.dart';
import '../../user_data/presentation/watch_later_screen.dart';
import 'app_theme_screen.dart';
import 'backup_restore_screen.dart';
import 'cloud_drive_screen.dart';
import 'custom_popup_play_screen.dart';
import 'help_screen.dart';
import 'legal_screen.dart';
import 'local_network_screen.dart';
import 'media_manager_screen.dart';
import 'statistics_screen.dart';
import 'status_saver_screen.dart';
import '../../transfer/presentation/transfer_screen.dart';

/// Phase 19: Me tab — full MX Player parity.
///
/// Top: 9-icon grid (3x3) inside a rounded card.
/// Then: Status Saver row.
/// Then: App Theme / Settings / Custom Pop-up Play group.
/// Then: Legal / Help group.
/// Bottom: Extra features (History, Favourites, Watch Later, Statistics).
class MeScreen extends StatelessWidget {
  const MeScreen({super.key});

  void _open(BuildContext context, Widget screen) {
    // rootNavigator:true → the screen is pushed above the shell, so the
    // persistent bottom nav bar (Local · Music · Transfer · Me) is hidden
    // for full-screen sub-features like Private Folder. Without this the
    // push lands on the shell's nested navigator and the tab bar stays
    // visible underneath.
    Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final grid = <_GridFeature>[
      _GridFeature(
        s.downloads,
        Icons.download_for_offline_outlined,
        // v0.99: real yt-dlp downloader (paste a link from any supported site
        // -> quality sheet -> stream or download). No longer a "soon" shell.
        () => _open(context, const DownloaderHomeScreen()),
      ),
      _GridFeature(
        s.fileTransfer,
        Icons.video_file_outlined,
        () => _open(context, const TransferScreen()),
        // Audit fix (Transfer real impl): pick files + QR + same-Wi-Fi
        // HTTP server wired (shelf + qr_flutter + network_info_plus).
        // Not Wi-Fi-Direct (needs native code) but works the
        // AirDroid / Snapdrop / Zapya-LAN way.
      ),
      _GridFeature(s.privateFolder, Icons.folder_special_outlined,
          () => context.push(Routes.privateFolder)),
      _GridFeature(s.videoPlaylists, Icons.queue_music_outlined,
          () => _open(context, const PlaylistsScreen())),
      _GridFeature(s.mediaManager, Icons.folder_zip_outlined,
          () => _open(context, const MediaManagerScreen())),
      _GridFeature(
        s.localNetwork,
        Icons.desktop_windows_outlined,
        () => _open(context, const LocalNetworkScreen()),
        comingSoon: true, // Audit Phase A1: SMB/FTP not actually wired
      ),
      _GridFeature(s.networkStream, Icons.public,
          () => _open(context, const NetworkStreamScreen())),
      _GridFeature(
        s.cloudDrive,
        Icons.cloud_outlined,
        () => _open(context, const CloudDriveScreen()),
        // Audit fix (standard high-quality): no OAuth, no actual
        // cloud SDK integration — connect state is in-memory only.
        // 7 providers shown but none actually authenticate.
        comingSoon: true,
      ),
      _GridFeature(s.recycleBin, Icons.delete_outline,
          () => _open(context, const RecycleBinScreen())),
    ];

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: Stack(
        children: [
          SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 14, 4, 14),
              child: Text(
                s.me,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            // 3x3 grid card. Each cell is sized to its content height
            // (icon + label) via mainAxisExtent so the rows sit a tight,
            // uniform 16 dp apart — a square aspect ratio left ~40 dp of
            // dead space per row and pushed the SOON badges adrift.
            // crossAxisCount stays adaptive-friendly; only the row height
            // is pinned, so it scales cleanly across phone/tablet widths.
            _Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: grid.length,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 8,
                    mainAxisExtent: 82,
                  ),
                  itemBuilder: (context, i) => _GridItem(grid[i]),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Status Saver
            _Card(
              child: _StatusSaverTile(
                  onTap: () => _open(context, const StatusSaverScreen())),
            ),
            const SizedBox(height: 12),

            // App Theme / Settings / Custom Pop-up Play
            _Card(
              child: Column(
                children: [
                  _ListTile(
                    icon: Icons.checkroom,
                    label: s.appTheme,
                    onTap: () => _open(context, const AppThemeScreen()),
                  ),
                  const _SubDivider(),
                  _ListTile(
                    icon: Icons.settings,
                    label: s.settings,
                    onTap: () => _open(context, const SettingsScreen()),
                  ),
                  const _SubDivider(),
                  _ListTile(
                    icon: Icons.crop_din,
                    label: s.popupPlay,
                    onTap: () =>
                        _open(context, const CustomPopupPlayScreen()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Phase 42: My Lists card — surface History/Favourites/Watch
            // Later in Me tab the way MX Player V3 does. They were already
            // reachable from the Local-tab Quick chips and the video option
            // menu, but daily users also expect to find them in Me.
            _Card(
              child: Column(
                children: [
                  _ListTile(
                    icon: Icons.history,
                    label: s.history,
                    onTap: () => _open(context, const HistoryScreen()),
                  ),
                  const _SubDivider(),
                  _ListTile(
                    icon: Icons.favorite_outline,
                    label: s.favourites,
                    onTap: () => _open(context, const FavouritesScreen()),
                  ),
                  const _SubDivider(),
                  _ListTile(
                    icon: Icons.watch_later_outlined,
                    label: s.watchLater,
                    onTap: () => _open(context, const WatchLaterScreen()),
                  ),
                  const _SubDivider(),
                  _ListTile(
                    icon: Icons.insights,
                    label: s.watchInsights,
                    onTap: () =>
                        _open(context, const WatchInsightsScreen()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Legal / Help
            _Card(
              child: Column(
                children: [
                  _ListTile(
                    icon: Icons.balance,
                    label: s.legal,
                    onTap: () => _open(context, const LegalScreen()),
                  ),
                  const _SubDivider(),
                  _ListTile(
                    icon: Icons.help_outline,
                    label: s.help,
                    onTap: () => _open(context, const HelpScreen()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Phase 41: Backup / Statistics / About — surface previously
            // orphaned screens so users can actually reach them.
            _Card(
              child: Column(
                children: [
                  _ListTile(
                    icon: Icons.backup_outlined,
                    label: s.backupRestore,
                    onTap: () =>
                        _open(context, const BackupRestoreScreen()),
                  ),
                  const _SubDivider(),
                  _ListTile(
                    icon: Icons.bar_chart,
                    label: s.statistics,
                    onTap: () =>
                        _open(context, const StatisticsScreen()),
                  ),
                  const _SubDivider(),
                  _ListTile(
                    icon: Icons.info_outline,
                    label: s.about,
                    onTap: () => _open(context, const AboutScreen()),
                  ),
                ],
              ),
            ),
            // Phase 45 (audit): MX Player V3 has a "Quit" button on the
            // Me page that's only visible when `generalQuitButton` is on
            // in Settings > General. SystemNavigator.pop() ends the
            // process cleanly (matches MX Player's behaviour: terminate
            // the app completely, unlike Back/Home).
            Consumer(builder: (ctx, r, _) {
              final showQuit = r
                  .watch(playerSettingsProvider)
                  .get(PlayerSetting.generalQuitButton);
              if (!showQuit) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _Card(
                  child: _ListTile(
                    icon: Icons.exit_to_app,
                    label: s.quit,
                    onTap: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (dctx) => AlertDialog(
                          backgroundColor: AppColors.darkSurface,
                          title: Text(
                            s.quitConfirmTitle,
                            style: const TextStyle(color: Colors.white),
                          ),
                          content: Text(
                            s.quitConfirmBody,
                            style: const TextStyle(color: Colors.white70),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dctx).pop(false),
                              child: Text(s.cancel),
                            ),
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dctx).pop(true),
                              child: Text(
                                s.quit,
                                style:
                                    const TextStyle(color: Colors.redAccent),
                              ),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) {
                        // SystemNavigator.pop closes the activity, which
                        // on Android terminates the process when there's
                        // no back-stack to return to.
                        SystemNavigator.pop();
                      }
                    },
                  ),
                ),
              );
            }),
            const SizedBox(height: 24),
          ],
        ),
      ),
        ],
      ),
    );
  }
}

class _GridFeature {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  /// Audit fix (Phase A1): mark features that look complete but
  /// aren't yet wired to a real backend. The grid item renders a
  /// "Coming soon" badge and shows a transparent disabled state.
  /// Honest UX > confidently-broken UX.
  final bool comingSoon;
  _GridFeature(
    this.label,
    this.icon,
    this.onTap, {
    this.comingSoon = false,
  });
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _GridItem extends StatelessWidget {
  final _GridFeature feature;
  const _GridItem(this.feature);

  @override
  Widget build(BuildContext context) {
    // "Coming soon" stubs still intercept the tap with an honest
    // snackbar, but render identically to live items — no badge, no
    // dimming — for a clean, uniform 3x3 grid.
    return InkWell(
      onTap: feature.comingSoon
          ? () {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(
                  content: Text(
                      '${feature.label} — ${AppStrings.of(context).comingSoon}'),
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                ));
            }
          : feature.onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(feature.icon, color: AppColors.accentBlue, size: 30),
            const SizedBox(height: 8),
            Text(
              feature.label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusSaverTile extends StatelessWidget {
  final VoidCallback onTap;
  const _StatusSaverTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // Phase 30: Solid green square (MX parity, not alpha-tinted)
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(
                Icons.download,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                AppStrings.of(context).statusSaver,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: AppColors.darkOnSurfaceMuted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _ListTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ListTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // Phase 30: MX uses WHITE outlined icons for these rows
            // (App Theme/Settings/Custom Pop-up Play/Legal/Help),
            // NOT the blue accent used by the 3x3 grid above.
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: AppColors.darkOnSurfaceMuted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _SubDivider extends StatelessWidget {
  const _SubDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, color: Colors.white10, indent: 52);
  }
}


