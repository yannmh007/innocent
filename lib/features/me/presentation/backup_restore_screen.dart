import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/backup/backup_service.dart';
import '../../../core/services/cache/library_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../../user_data/user_data_providers.dart';
import 'cloud_drive_screen.dart';

import '../../../core/localization/app_strings.dart';
/// Backup & Restore screen — export/import app settings and playlists.
///
/// Phase 41: merged the two prior backup screens. The presentation comes
/// from the original Me-tab placeholder (info card + colour-coded action
/// cards + "What gets backed up" list), the working export/import logic
/// comes from the previously-orphaned `settings/backup_screen.dart`
/// (now removed). Cloud actions remain informational because OAuth is
/// not bundled yet.
class BackupRestoreScreen extends ConsumerStatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  ConsumerState<BackupRestoreScreen> createState() =>
      _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends ConsumerState<BackupRestoreScreen> {
  bool _working = false;

  void _snack(String msg, {Duration? duration}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: duration ?? const Duration(seconds: 3)),
    );
  }

  Future<void> _export() async {
    setState(() => _working = true);
    try {
      final service = BackupService(ref.read(userDataServiceProvider));
      final path = await service.exportToFile();
      if (!mounted) return;
      final s = AppStrings.of(context);
      await Clipboard.setData(ClipboardData(text: path));
      if (!mounted) return;
      _snack(s.bkExported(path));
    } catch (e) {
      if (!mounted) return;
      _snack(AppStrings.of(context).bkFailed('$e'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _import() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).restoreBackupTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(
          AppStrings.of(context).bkRestoreWarn,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(AppStrings.of(context).cancel,
                style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(AppStrings.of(context).restore,
                style: const TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    // The confirm dialog is an await; the screen underneath can be gone by the
    // time it resolves (a back gesture, a deep link, a route restore).
    if (!mounted) return;

    setState(() => _working = true);
    try {
      final service = BackupService(ref.read(userDataServiceProvider));
      final result = await service.importFromFile();
      if (!mounted) return;
      final s = AppStrings.of(context);
      if (result == null) {
        _snack(s.bkNoFile);
      } else {
        ref.invalidate(favouritesProvider);
        ref.invalidate(playlistsProvider);
        ref.invalidate(bookmarksProvider);
        ref.invalidate(historyProvider);
        ref.invalidate(recycleBinProvider);
        _snack(s.bkRestored('${result.favourites}', '${result.playlists}',
            '${result.bookmarks}', '${result.history}'));
      }
    } catch (e) {
      if (!mounted) return;
      _snack(AppStrings.of(context).bkFailed('$e'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _clearLibraryCache() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).clearLibraryCacheTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(
          AppStrings.of(context).bkClearWarn,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(AppStrings.of(context).cancel,
                style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child:
                Text(AppStrings.of(context).clear, style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await LibraryCache().clear();
    if (!mounted) return;
    _snack(AppStrings.of(context).bkCacheCleared);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).backupRestore)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Info card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline,
                    color: AppColors.accentBlue70,
                    size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    s.bkInfo,
                    style: const TextStyle(
                      color: AppColors.white60,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
                if (_working) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          _sectionTitle(s.bkSectionBackup),
          const SizedBox(height: 12),
          _actionCard(
            context,
            icon: Icons.backup_outlined,
            title: s.bkExport,
            subtitle: s.bkExportSub,
            color: AppColors.primaryBlue,
            onTap: _working ? null : _export,
          ),
          const SizedBox(height: 28),
          _sectionTitle(s.bkSectionRestore),
          const SizedBox(height: 12),
          _actionCard(
            context,
            icon: Icons.restore,
            title: s.bkRestoreFile,
            subtitle: s.bkRestoreFileSub,
            color: const Color(0xFFFF9800),
            onTap: _working ? null : _import,
          ),
          // Cloud Drive lives here now (it left the Me grid, 2026-10-06):
          // backing up to and streaming from the cloud is one place. It
          // replaces "Backup to Cloud" / "Restore from Cloud", two cards
          // that only ever said "requires sign-in".
          const SizedBox(height: 28),
          _sectionTitle(s.bkSectionCloud),
          const SizedBox(height: 12),
          _actionCard(
            context,
            icon: Icons.cloud_outlined,
            title: s.cloudDrive,
            subtitle: s.bkCloudSub,
            color: const Color(0xFF29B6F6),
            badge: s.comingSoon,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const CloudDriveScreen())),
          ),
          const SizedBox(height: 28),
          _sectionTitle(s.bkSectionCache),
          const SizedBox(height: 12),
          _actionCard(
            context,
            icon: Icons.delete_sweep_outlined,
            title: s.bkClearCache,
            subtitle: s.bkClearCacheSub,
            color: AppColors.error,
            onTap: _working ? null : _clearLibraryCache,
          ),
          const SizedBox(height: 28),
          _sectionTitle(s.bkWhat),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _backupItem(Icons.settings, s.bkItemSettings),
                const Divider(height: 24, color: Colors.white10),
                _backupItem(Icons.playlist_play, s.bkItemPlaylists),
                const Divider(height: 24, color: Colors.white10),
                _backupItem(Icons.favorite_outline, s.bkItemFavourites),
                const Divider(height: 24, color: Colors.white10),
                _backupItem(Icons.history, s.bkItemHistory),
                const Divider(height: 24, color: Colors.white10),
                _backupItem(Icons.watch_later_outlined, s.bkItemLater),
                const Divider(height: 24, color: Colors.white10),
                _backupItem(Icons.bookmark_outline, s.bkItemBookmarks),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Color(0xFFFF9800),
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _actionCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback? onTap,
    String? badge,
  }) {
    final disabled = onTap == null;
    return Material(
      color: AppColors.darkSurface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color
                      .withOpacity(disabled ? 0.07 : 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon,
                    color: disabled
                        ? color.withOpacity(0.4)
                        : color,
                    size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: disabled
                                  ? AppColors.white40
                                  : Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.white10,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(badge,
                                style: const TextStyle(
                                    color: AppColors.white70,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.white50,
                        fontSize: 12,
                        // Room for Burmese, whose stacked marks collide at
                        // the default line height.
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right,
                  color: AppColors.white30, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _backupItem(IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, color: AppColors.accentBlue70, size: 18),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ],
    );
  }
}
