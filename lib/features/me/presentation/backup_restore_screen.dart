import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/backup/backup_service.dart';
import '../../../core/services/cache/library_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../../user_data/user_data_providers.dart';

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
      _snack('Exported to: $path');
      await Clipboard.setData(ClipboardData(text: path));
      if (!mounted) return;
      _snack('Path copied to clipboard');
    } catch (e) {
      if (!mounted) return;
      _snack('Export failed: $e');
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
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This will REPLACE all current favourites, playlists, bookmarks, history, and recycle bin entries with those from the backup file.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(AppStrings.of(context).cancel,
                style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(AppStrings.of(context).restore,
                style: TextStyle(color: AppColors.accentBlue)),
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
      if (result == null) {
        _snack('No file selected');
      } else {
        ref.invalidate(favouritesProvider);
        ref.invalidate(playlistsProvider);
        ref.invalidate(bookmarksProvider);
        ref.invalidate(historyProvider);
        ref.invalidate(recycleBinProvider);
        _snack(
          'Restored: ${result.favourites} favourites, '
          '${result.playlists} playlists, ${result.bookmarks} bookmarks, '
          '${result.history} history, ${result.recycleBin} recycle',
        );
      }
    } catch (e) {
      if (!mounted) return;
      _snack('Restore failed: $e');
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
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Next app open will re-scan all videos from device storage. This is safe but slower the next time.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(AppStrings.of(context).cancel,
                style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child:
                Text(AppStrings.of(context).clear, style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await LibraryCache().clear();
    if (!mounted) return;
    _snack('Library cache cleared. Restart app to re-scan.');
  }

  @override
  Widget build(BuildContext context) {
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
                Icon(Icons.info_outline,
                    color: AppColors.accentBlue70,
                    size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: const Text(
                    'Back up your settings, playlists, and preferences. Restore them on any device.',
                    style: TextStyle(
                      color: AppColors.white60,
                      fontSize: 13,
                      height: 1.4,
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
          _sectionTitle('Backup'),
          const SizedBox(height: 12),
          _actionCard(
            context,
            icon: Icons.backup_outlined,
            title: 'Export backup to file',
            subtitle:
                'Save favourites, playlists, bookmarks & history as JSON',
            color: AppColors.primaryBlue,
            onTap: _working ? null : _export,
          ),
          const SizedBox(height: 12),
          _actionCard(
            context,
            icon: Icons.cloud_upload_outlined,
            title: 'Backup to Cloud',
            subtitle: 'Save backup to Google Drive or other cloud storage',
            color: const Color(0xFF4CAF50),
            onTap: () => _snack('Cloud backup requires sign-in'),
          ),
          const SizedBox(height: 28),
          _sectionTitle('Restore'),
          const SizedBox(height: 12),
          _actionCard(
            context,
            icon: Icons.restore,
            title: 'Restore from file',
            subtitle: 'Import settings from a local backup file',
            color: const Color(0xFFFF9800),
            onTap: _working ? null : _import,
          ),
          const SizedBox(height: 12),
          _actionCard(
            context,
            icon: Icons.cloud_download_outlined,
            title: 'Restore from Cloud',
            subtitle: 'Download and restore from cloud backup',
            color: const Color(0xFF9C27B0),
            onTap: () => _snack('Cloud restore requires sign-in'),
          ),
          const SizedBox(height: 28),
          _sectionTitle('Cache'),
          const SizedBox(height: 12),
          _actionCard(
            context,
            icon: Icons.delete_sweep_outlined,
            title: 'Clear library cache',
            subtitle: 'Forces re-scan of videos on next launch',
            color: AppColors.error,
            onTap: _working ? null : _clearLibraryCache,
          ),
          const SizedBox(height: 28),
          _sectionTitle('What gets backed up'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _backupItem(Icons.settings, 'App settings & preferences'),
                const Divider(height: 24, color: Colors.white10),
                _backupItem(Icons.playlist_play, 'Video playlists'),
                const Divider(height: 24, color: Colors.white10),
                _backupItem(Icons.favorite_outline, 'Favourites'),
                const Divider(height: 24, color: Colors.white10),
                _backupItem(Icons.history, 'Watch history'),
                const Divider(height: 24, color: Colors.white10),
                _backupItem(Icons.watch_later_outlined, 'Watch later list'),
                const Divider(height: 24, color: Colors.white10),
                _backupItem(Icons.bookmark_outline, 'Bookmarks'),
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
                    Text(
                      title,
                      style: TextStyle(
                        color: disabled
                            ? AppColors.white40
                            : Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: AppColors.white50,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right,
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
