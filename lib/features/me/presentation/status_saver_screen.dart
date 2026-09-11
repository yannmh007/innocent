import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/app_snackbar.dart';

import '../../../core/localization/app_strings.dart';
/// Status Saver — lets the user view and keep WhatsApp / WA Business
/// statuses (images & videos) before they disappear.
///
/// Implementation notes:
/// - Statuses live in the (hidden) `.Statuses` folders under WhatsApp's
///   shared-media directories. We read them directly with `dart:io` after
///   the media permission is granted (the `.nomedia` only hides them from
///   the gallery, not from direct file access).
/// - "Save" copies the file into a public Pictures/Movies folder so it
///   shows up in the gallery, falling back to the app's external dir if a
///   device's scoped-storage rules block the public write.
class StatusSaverScreen extends StatefulWidget {
  const StatusSaverScreen({super.key});

  @override
  State<StatusSaverScreen> createState() => _StatusSaverScreenState();
}

class _StatusSaverScreenState extends State<StatusSaverScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  bool _loading = true;
  bool _permissionDenied = false;
  List<File> _images = [];
  List<File> _videos = [];

  // WhatsApp + WhatsApp Business status folders (new Android 11+ media
  // paths first, then the legacy top-level paths for older devices).
  static const List<String> _statusDirs = [
    '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/.Statuses',
    '/storage/emulated/0/WhatsApp/Media/.Statuses',
    '/storage/emulated/0/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/.Statuses',
    '/storage/emulated/0/WhatsApp Business/Media/.Statuses',
  ];
  static const Set<String> _imageExt = {'.jpg', '.jpeg', '.png', '.webp'};
  static const Set<String> _videoExt = {'.mp4', '.3gp', '.mkv', '.webm'};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _permissionDenied = false;
    });

    // A throw here (plugin error, or the user backgrounding the app mid-prompt)
    // used to leave _loading stuck at true — an endless spinner with no way out
    // but restarting the app. Treat any failure as "no access".
    PermissionState ps;
    try {
      ps = await PhotoManager.requestPermissionExtend();
    } catch (e) {
      debugPrint('status_saver permission failed: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _permissionDenied = true;
        });
      }
      return;
    }
    if (!ps.hasAccess) {
      if (mounted) {
        setState(() {
          _loading = false;
          _permissionDenied = true;
        });
      }
      return;
    }

    final imgs = <File>[];
    final vids = <File>[];
    // Some devices expose the SAME status file under both the Android 11+
    // media path and the legacy top-level path. Track basenames so a file
    // isn't listed twice (WhatsApp status names are already unique hashes).
    final seen = <String>{};
    for (final dirPath in _statusDirs) {
      final dir = Directory(dirPath);
      try {
        if (!await dir.exists()) continue;
      } catch (e) {
        // An unreadable/denied path must skip, not abort the whole scan.
        debugPrint('status_saver dir check failed ($dirPath): $e');
        continue;
      }
      try {
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final base = p.basename(entity.path);
          final name = base.toLowerCase();
          if (name == '.nomedia') continue;
          if (!seen.add(base)) continue;
          final ext = p.extension(name);
          if (_imageExt.contains(ext)) {
            imgs.add(entity);
          } else if (_videoExt.contains(ext)) {
            vids.add(entity);
          }
        }
      } catch (_) {
        // Unreadable folder on this device — skip it.
      }
    }

    // Pre-read modification times ONCE instead of calling lastModifiedSync()
    // inside the comparator — a sort does O(n log n) comparisons, so the old
    // code did hundreds of blocking disk reads on the UI thread and the
    // screen appeared to hang on folders with many statuses.
    final mtime = <String, int>{};
    for (final f in [...imgs, ...vids]) {
      try {
        mtime[f.path] = (await f.lastModified()).millisecondsSinceEpoch;
      } catch (_) {
        mtime[f.path] = 0;
      }
    }
    int byNewest(File a, File b) =>
        (mtime[b.path] ?? 0).compareTo(mtime[a.path] ?? 0);

    imgs.sort(byNewest);
    vids.sort(byNewest);

    if (!mounted) return;
    setState(() {
      _images = imgs;
      _videos = vids;
      _loading = false;
    });
  }

  Future<String?> _copyInto(File src, String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      final dest = p.join(dirPath, p.basename(src.path));
      await src.copy(dest);
      return dest;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(File file, {required bool isVideo}) async {
    String? savedLocation;
    // Preferred path: register the saved copy with MediaStore via
    // photo_manager. This is what actually makes it show up in the device
    // gallery, and it works under Android 10+ scoped storage where a raw
    // File.copy into /Pictures is either blocked or stays un-indexed (so
    // the file "saves" but is invisible).
    try {
      final title = p.basename(file.path);
      final AssetEntity? asset = isVideo
          ? await PhotoManager.editor.saveVideo(file, title: title)
          : await PhotoManager.editor.saveImageWithPath(file.path, title: title);
      if (asset != null) savedLocation = 'gallery';
    } catch (_) {
      // Fall through to the raw-copy fallback below.
    }

    // Fallback for older devices, or if the MediaStore save failed: copy
    // the bytes directly, then drop to the app's external dir as a last
    // resort so the user at least keeps the file.
    if (savedLocation == null) {
      final publicDir = isVideo
          ? '/storage/emulated/0/Movies/Innocent'
          : '/storage/emulated/0/Pictures/Innocent';
      var saved = await _copyInto(file, publicDir);
      if (saved == null) {
        final appDir = await getExternalStorageDirectory();
        if (appDir != null) {
          saved = await _copyInto(file, p.join(appDir.path, 'SavedStatus'));
        }
      }
      if (saved != null) savedLocation = p.dirname(saved);
    }

    if (!mounted) return;
    if (savedLocation != null) {
      AppSnackbar.global('Saved to $savedLocation');
    } else {
      AppSnackbar.globalError('Could not save — storage not writable');
    }
  }

  void _previewImage(File file) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            InteractiveViewer(
              child: Center(child: Image.file(file)),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
            Positioned(
              bottom: 12,
              right: 12,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accentBlue),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _save(file, isVideo: false);
                },
                icon: const Icon(Icons.download, size: 18),
                label: Text(AppStrings.of(context).save),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _playVideo(File file) {
    context.push(Routes.player, extra: {
      'uri': file.path,
      'title': p.basename(file.path),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: Text(AppStrings.of(context).statusSaver),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, size: 22),
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.primaryBlue,
          labelColor: AppColors.primaryBlue,
          unselectedLabelColor: AppColors.darkOnSurfaceMuted,
          tabs: const [
            Tab(text: 'IMAGES'),
            Tab(text: 'VIDEOS'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _permissionDenied
              ? _permissionState()
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildGrid(_images, isVideo: false),
                    _buildGrid(_videos, isVideo: true),
                  ],
                ),
    );
  }

  Widget _buildGrid(List<File> files, {required bool isVideo}) {
    if (files.isEmpty) {
      return _emptyState(
        isVideo ? Icons.videocam_outlined : Icons.image_outlined,
        isVideo ? 'No status videos found' : 'No status images found',
        'Open a status on WhatsApp first, then come back and refresh.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.72,
        ),
        itemCount: files.length,
        itemBuilder: (ctx, i) => _tile(files[i], isVideo: isVideo),
      ),
    );
  }

  Widget _tile(File file, {required bool isVideo}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: GestureDetector(
        onTap: () => isVideo ? _playVideo(file) : _previewImage(file),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isVideo)
              Container(
                color: AppColors.darkSurface,
                child: const Center(
                  child: Icon(Icons.movie_outlined,
                      color: AppColors.white30, size: 34),
                ),
              )
            else
              Image.file(
                file,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: AppColors.darkSurface,
                  child: const Center(
                    child: Icon(Icons.broken_image_outlined,
                        color: AppColors.white30, size: 28),
                  ),
                ),
              ),
            if (isVideo)
              const Center(
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white70, size: 40),
              ),
            // Save button
            Positioned(
              right: 4,
              bottom: 4,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _save(file, isVideo: isVideo),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.download,
                        color: Colors.white, size: 18),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_off_outlined,
                size: 64, color: AppColors.white20),
            const SizedBox(height: 16),
            Text(AppStrings.of(context).storagePermissionNeeded,
              style: const TextStyle(
                color: AppColors.white60,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(AppStrings.of(context).statusPermissionHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.white40, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accentBlue),
                  onPressed: _load,
                  child: Text(AppStrings.of(context).permissionGrant),
                ),
                OutlinedButton(
                  onPressed: () => PhotoManager.openSetting(),
                  child: Text(AppStrings.of(context).permissionOpenSettings),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(IconData icon, String title, String subtitle) {
    // Wrapped in a scroll view so RefreshIndicator pull-to-refresh works
    // even when the list is empty.
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 64, color: AppColors.white20),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.white60,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppColors.white40, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
