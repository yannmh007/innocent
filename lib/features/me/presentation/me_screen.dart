import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/adb/adb_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../about/about_screen.dart';
import '../../android_data/presentation/android_data_screen.dart';
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
import 'backup_restore_screen.dart';
import 'help_screen.dart';
import 'local_network_screen.dart';
import 'media_manager_screen.dart';
import 'status_saver_screen.dart';
import '../../transfer/presentation/transfer_screen.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import '../../../core/theme/tab_title.dart';

/// Phase 19: Me tab — full MX Player parity.
///
/// Top: 9-icon grid (3x3) inside a rounded card.
/// Then: Status Saver and Hidden files (Android/data).
/// Then: Your library (History, Favourites, Watch later, Insights).
/// Then: Settings / Backup & Restore, and Help / About.
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
    // The owner's order (2026-10-06), three by three:
    //   Download        File Transfer   Private Folder
    //   Movies          Media Manager   Local Network
    //   Network Stream  Video Playlists Recycle Bin
    // Cloud Drive left the grid for Backup & Restore (it is a backup and
    // cloud-streaming feature, and not ready yet); Movies took its place.
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
      ),
      _GridFeature(s.privateFolder, Icons.folder_special_outlined,
          () => context.push(Routes.privateFolder)),
      // The Movies hub, as the Video tab's red chip opens it: a top-level
      // route on the root navigator, so the tab bar is not drawn under it.
      _GridFeature(s.vhVideoChip, Icons.movie_outlined,
          () => context.push(Routes.videoHub)),
      _GridFeature(s.mediaManager, Icons.folder_zip_outlined,
          () => _open(context, const MediaManagerScreen())),
      _GridFeature(
        s.localNetwork,
        Icons.desktop_windows_outlined,
        () => _open(context, const LocalNetworkScreen()),
      ),
      _GridFeature(s.networkStream, Icons.public,
          () => _open(context, const NetworkStreamScreen())),
      _GridFeature(s.videoPlaylists, Icons.queue_music_outlined,
          () => _open(context, const PlaylistsScreen())),
      _GridFeature(s.recycleBin, Icons.delete_outline,
          () => _open(context, const RecycleBinScreen())),
    ];

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: Stack(
        children: [
          // A phone-width column on a tablet or TV (as the Video tab): a
          // list of settings 1200 dp wide read like a spreadsheet.
          TabletConstrainedWidth(
            maxWidth: 840,
            child: SafeArea(
        child: ListView(
          // MX PLAYER'S "ME", measured from its screenshots (2026-10-04, a
          // 411 dp phone): cards 16 dp from the edges with a 6 dp corner, a
          // 20 sp title, grid rows 72 dp apart, list rows 50 dp, a 23 dp
          // Status Saver square. This had 12 dp margins, a 12 dp corner, a
          // 22 sp title and 98 dp grid rows — the same content a third
          // taller, which is what read as loose next to MX.
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            Padding(
              // Where an AppBar puts its title on the other tabs: 16 dp in
              // (the list's own 16), centred in the first 56 dp.
              padding: const EdgeInsets.fromLTRB(0, 16, 0, 16),
              child: Text(
                s.me,
                style: kTabTitleStyle.copyWith(color: Colors.white),
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
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    // The label's line grows with the system font size.
                    mainAxisExtent:
                        64 + MediaQuery.textScalerOf(context).scale(20) - 20,
                  ),
                  itemBuilder: (context, i) => _GridItem(grid[i]),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // BELOW THE GRID (redesigned 2026-10-06, owner's request: "too
            // many rows, cluttered, not premium"). It was 13 rows in 6 cards.
            // Now, the way YouTube's "You", Netflix's "My Netflix" and
            // MX Player's Me are laid out — things you made first, then the
            // app's own housekeeping, each said once:
            //   Status Saver                       (MX's signature row)
            //   Your library   History · Favourites · Watch later · Insights
            //   Settings  (+ App theme, Pop-up play)   Backup & Restore
            //   Help                                    About (+ Legal)
            // Nothing was removed: App theme and Custom pop-up play are in
            // Settings, Statistics is inside Insights, Legal inside About.
            _Card(
              child: Column(
                children: [
                  _MeRow(
                    icon: Icons.download_rounded,
                    tint: const Color(0xFF25D366),
                    filled: true,
                    label: s.statusSaver,
                    onTap: () => _open(context, const StatusSaverScreen()),
                  ),
                  // Other apps' files, beside WhatsApp's statuses: Telegram's
                  // downloads and every app's private folder, read over
                  // Innocent's own ADB connection. It used to be reachable
                  // only from the bottom of Settings → List, as "ADB
                  // connection (experimental)".
                  const Divider(
                      height: 1, indent: 64, color: AppColors.darkDivider),
                  // Connected, it says so — and that the videos are in the
                  // Video tab as well, which is where people look for them.
                  ValueListenableBuilder<bool?>(
                    valueListenable: AdbService.instance.live,
                    builder: (context, live, _) => _MeRow(
                      icon: Icons.snippet_folder_rounded,
                      tint: const Color(0xFF2AABEE),
                      filled: true,
                      label: s.hfTitle,
                      hint: live == true ? s.hfLive : s.hfHint,
                      hintColor: live == true ? AppColors.success : null,
                      onTap: () => _open(context, const AndroidDataScreen()),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            _Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 2, bottom: 10),
                      child: Text(
                        s.meLibrary,
                        style: const TextStyle(
                          color: AppColors.white60,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Shortcut(
                          icon: Icons.history_rounded,
                          tint: const Color(0xFF5AC8FA),
                          label: s.history,
                          onTap: () => _open(context, const HistoryScreen()),
                        ),
                        _Shortcut(
                          icon: Icons.favorite_rounded,
                          tint: const Color(0xFFFF5A7A),
                          label: s.favourites,
                          onTap: () =>
                              _open(context, const FavouritesScreen()),
                        ),
                        _Shortcut(
                          icon: Icons.watch_later_rounded,
                          tint: const Color(0xFFFFB020),
                          label: s.watchLater,
                          onTap: () =>
                              _open(context, const WatchLaterScreen()),
                        ),
                        _Shortcut(
                          icon: Icons.insights_rounded,
                          tint: const Color(0xFFAF7BFF),
                          label: s.meInsights,
                          onTap: () =>
                              _open(context, const WatchInsightsScreen()),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            _Card(
              child: Column(
                children: [
                  _MeRow(
                    icon: Icons.settings_rounded,
                    tint: const Color(0xFF8E8E93),
                    label: s.settings,
                    hint: s.meSettingsHint,
                    onTap: () => _open(context, const SettingsScreen()),
                  ),
                  _MeRow(
                    icon: Icons.cloud_sync_rounded,
                    tint: const Color(0xFF29B6F6),
                    label: s.backupRestore,
                    hint: s.meBackupHint,
                    onTap: () =>
                        _open(context, const BackupRestoreScreen()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            _Card(
              child: Column(
                children: [
                  _MeRow(
                    icon: Icons.help_rounded,
                    tint: const Color(0xFF34C759),
                    label: s.help,
                    hint: s.meHelpHint,
                    onTap: () => _open(context, const HelpScreen()),
                  ),
                  _MeRow(
                    icon: Icons.info_rounded,
                    tint: AppColors.accentBlue,
                    label: s.about,
                    hint: s.meAboutHint,
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
  _GridFeature(this.label, this.icon, this.onTap);
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(6),
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
    // Every tile in the grid is a working feature now: the last stub
    // (Cloud Drive) moved into Backup & Restore, where it says "Coming soon"
    // in words.
    return InkWell(
      onTap: feature.onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(feature.icon, color: AppColors.accentBlue, size: 28),
            const SizedBox(height: 6),
            // SHRINK, DON'T CUT. The rows are a fixed 64 dp, so a label gets
            // one line; a long one ("မီဒီယာ စီမံခန့်ခွဲမှု" on a 360px phone)
            // was cut to "မီဒီယာ စီမံခန့်…". Scaling it down a little keeps
            // the whole word readable.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                feature.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
              ),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            // Phase 30: MX uses WHITE outlined icons for these rows
            // (App Theme/Settings/Custom Pop-up Play/Legal/Help),
            // NOT the blue accent used by the 3x3 grid above.
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 14.5),
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

/// A Me row: a tinted icon tile, the name, and (optionally) one line saying
/// what is inside — so "Settings" tells you App theme lives there now.
class _MeRow extends StatelessWidget {
  const _MeRow({
    required this.icon,
    required this.tint,
    required this.label,
    required this.onTap,
    this.hint,
    this.hintColor,
    this.filled = false,
  });

  final IconData icon;
  final Color tint;
  final String label;
  final String? hint;

  /// The hint's colour when it reports a state (connected) rather than
  /// describing the row.
  final Color? hintColor;
  final VoidCallback onTap;

  /// A solid tile with a white glyph (Status Saver, MX's green square)
  /// instead of the tinted one.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final mm = AppStrings.of(context).locale.languageCode == 'my';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: filled ? tint : tint.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: filled ? Colors.white : tint, size: 21),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      height: mm ? 1.5 : 1.25,
                    ),
                  ),
                  if (hint != null)
                    Text(
                      hint!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: hintColor ?? AppColors.white50,
                        fontSize: 12.5,
                        height: mm ? 1.5 : 1.3,
                      ),
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.darkOnSurfaceMuted, size: 22),
          ],
        ),
      ),
    );
  }
}

/// One of the four "Your library" shortcuts: a tinted circle and a label.
class _Shortcut extends StatelessWidget {
  const _Shortcut({
    required this.icon,
    required this.tint,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color tint;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: tint, size: 23),
              ),
              const SizedBox(height: 7),
              // Two centred lines rather than one shrunk one: Burmese
              // names ("နောက်မှ ကြည့်ရန်") are wider than the quarter they
              // get, and squeezed to fit they ran into each other.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Text(
                  label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    height: Localizations.localeOf(context).languageCode == 'my'
                        ? 1.45
                        : 1.25,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
