import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/services/adb/adb_service.dart';
import '../../../../core/di/core_providers.dart';
import '../../../../core/services/biometric/biometric_service.dart';
import '../../../../core/services/file_ops/file_ops_service.dart';
import '../../../../core/services/file_transfer/file_transfer_service.dart';
import '../../../../core/services/preferences/player_settings_service.dart';
import '../../../../core/services/thumbnail/thumbnail_cache.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/ui/app_snackbar.dart';
import '../../../private_folder/data/private_folder_providers.dart';
import '../../../shell/shell_screen.dart';
import '../../../user_data/domain/user_data_models.dart';
import '../../../user_data/user_data_providers.dart';
import '../../domain/video.dart';
import '../library_provider.dart';
import 'destination_picker.dart';
import 'media_identity_migrator.dart';

/// The actions both selection modes offer, implemented ONCE.
///
/// ─── WHY THIS FILE EXISTS ────────────────────────────────────────────────
///
/// Selecting videos and selecting folders are the same operation with a
/// different way of naming the files: a folder selection is just "every video
/// underneath these paths". Every action beyond that is identical.
///
/// They had drifted apart badly. The folder bar had a real bulk vault import
/// with a progress dialog and a cancel button; the video bar had a snackbar
/// that claimed files were hidden and hid nothing. Neither offered File
/// Transfer or Properties, and only one offered Move and Copy.
///
/// Putting the implementations here means an action cannot be real in one
/// selection mode and theatre in the other, and a fix lands in both.
class BulkActions {
  const BulkActions._();

  /// Only `file://` and plain paths are real files on disk. `content://` is a
  /// system handle with no path behind it, and `adb://` needs pulling first.
  static String? pathOf(String uri) {
    if (uri.startsWith('file://')) {
      try {
        return Uri.parse(uri).toFilePath();
      } catch (_) {
        return null;
      }
    }
    if (uri.startsWith('/')) return uri;
    return null;
  }

  // ── Move / Copy ────────────────────────────────────────────────────────

  /// Move or copy [videos], carrying their saved state and sidecars along.
  ///
  /// Returns true when something actually happened, so the caller can clear
  /// its selection only on success and leave it intact after a cancel.
  static Future<bool> moveOrCopy(
    BuildContext context,
    WidgetRef ref, {
    required List<Video> videos,
    required bool move,
  }) async {
    final s = AppStrings.of(context);

    // Settings → General → "Allow editing" is the switch people turn off
    // before handing the phone to someone else. Moving is editing; copying
    // creates something new and changes nothing, so only Move is gated.
    if (move &&
        !ref
            .read(playerSettingsProvider)
            .get(PlayerSetting.generalAllowEditing)) {
      AppSnackbar.global(s.selectionEditingOff);
      return false;
    }

    final paths = <String>[];
    final pathToUri = <String, String>{};
    for (final v in videos) {
      final path = pathOf(v.uri);
      if (path != null) {
        paths.add(path);
        pathToUri[path] = v.uri;
      }
    }
    if (paths.isEmpty) {
      AppSnackbar.global(s.selectionNoFiles);
      return false;
    }

    final sourceDirs = <String>{for (final path in paths) p.dirname(path)};
    final choice = await DestinationPicker.show(
      context,
      title: move
          ? '${s.selectionMoveTitle} · ${paths.length}'
          : '${s.selectionCopyTitle} · ${paths.length}',
      excludePaths: move ? sourceDirs : const <String>{},
    );
    if (choice == null) return false;

    AppSnackbar.global(s.selectionWorking);
    final ops = ref.read(fileOpsServiceProvider);
    final result = move
        ? await ops.moveAll(
            sources: paths,
            destinationDir: choice.path,
            collision: choice.collision,
          )
        : await ops.copyAll(
            sources: paths,
            destinationDir: choice.path,
            collision: choice.collision,
          );

    // Both ends. Without the ORIGINALS in this list a moved file leaves a
    // ghost in MediaStore that other apps will try to open.
    await ops.notifyMediaStore(
      written: result.writtenPaths,
      removed: move ? paths : const <String>[],
    );

    if (move) {
      await ThumbnailCache.instance.invalidateAll(paths);
      final remap = <String, String>{};
      result.mapping.forEach((from, to) {
        final oldUri = pathToUri[from];
        if (oldUri == null) return;
        remap[oldUri] =
            oldUri.startsWith('file://') ? Uri.file(to).toString() : to;
      });
      if (remap.isNotEmpty) {
        await MediaIdentityMigrator.migrateAll(ref, oldToNew: remap);
      }
    }

    ref.invalidate(foldersProvider);
    ref.invalidate(allVideosProvider);

    final parts = <String>['${move ? s.selectionMoved : s.selectionCopied} '
        '${result.succeeded}'];
    if (result.skipped > 0) parts.add('${result.skipped} skipped');
    if (result.hasFailures) parts.add('${result.failures.length} failed');
    final msg = parts.join(' · ');
    if (result.hasFailures) {
      AppSnackbar.globalError(msg);
    } else {
      AppSnackbar.global(msg);
    }
    return true;
  }

  // ── Private Folder ─────────────────────────────────────────────────────

  /// Move [videos] into the vault.
  ///
  /// Identity is verified FIRST, before anything is moved: without it, anyone
  /// holding an unlocked phone could bury files where the owner cannot find
  /// them. The PIN must already exist — creating one at this moment, under
  /// time pressure, is how people pick a PIN they forget.
  static Future<bool> lockInPrivateFolder(
    BuildContext context,
    WidgetRef ref, {
    required List<Video> videos,
  }) async {
    final s = AppStrings.of(context);
    if (videos.isEmpty) {
      AppSnackbar.global(s.noVideosToLock);
      return false;
    }
    final svc = ref.read(privateFolderServiceProvider);
    if (!await svc.hasPin()) {
      AppSnackbar.global(s.setPinFirst);
      return false;
    }
    if (!context.mounted) return false;

    final bio = ref.read(biometricServiceProvider);
    if (await bio.canCheck()) {
      if (!context.mounted) return false;
      final ok = await bio.authenticate(reason: s.verifyToLock);
      if (!ok) {
        AppSnackbar.global(s.lockCancelled);
        return false;
      }
    }
    if (!context.mounted) return false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(s.lockInPrivateFolder,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(s.confirmLockBody(videos.length),
            style: const TextStyle(color: AppColors.white70, fontSize: 13.5)),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(s.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(s.lock,
                style: const TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;

    // Captured before the loop: `ref` belongs to the screen that started this,
    // and vaulting a hundred videos is a long enough operation for the user to
    // leave. See MediaIdentityMigrator for the same reasoning.
    final historyNotifier = ref.read(historyProvider.notifier);
    final resume = ref.read(resumeStorageProvider);
    var done = 0;
    for (final v in videos) {
      try {
        await svc.importToVault(videoUri: v.uri, videoTitle: v.title);
        // Erase the public trail. A vaulted video whose history entry survives
        // still shows in Continue Watching, by name, on a screen anyone can
        // see — which defeats the point of vaulting it.
        try {
          await historyNotifier.deleteEntry(v.uri);
          await resume.clearPosition(v.uri);
          final last = await resume.getLastPlaying();
          if (last?.uri == v.uri) await resume.clearLastPlaying();
          // …and every other list that would still name it. Favourites,
          // playlists, Watch Later and bookmarks all sit one tap from the Me
          // tab and print the title in plain text.
          await MediaIdentityMigrator.purgePublicTraces(ref, v.uri);
        } catch (e) {
          if (kDebugMode) debugPrint('bulk_actions.lock-trail: $e');
        }
        done++;
      } catch (e) {
        if (kDebugMode) debugPrint('bulk_actions.lock: $e');
      }
    }
    ref.invalidate(allVideosProvider);
    ref.invalidate(foldersProvider);
    ref.invalidate(privateFolderUrisProvider);
    AppSnackbar.global(s.lockedCount(done));
    return true;
  }

  // ── File Transfer ──────────────────────────────────────────────────────

  /// Queue [videos] on the Transfer tab and go there.
  ///
  /// `adb://` videos live inside another app's private directory, which the
  /// LAN server cannot read, so they are pulled to a local copy first — the
  /// same thing the Transfer picker does.
  static Future<bool> sendToTransfer(
    BuildContext context,
    WidgetRef ref, {
    required List<Video> videos,
  }) async {
    final s = AppStrings.of(context);
    final files = <SharedFile>[];
    var needsAdb = false;

    for (final v in videos) {
      String? path;
      if (v.uri.startsWith('adb://')) {
        final pulled =
            await AdbService.instance.pullForPlayback(v.uri.substring(6));
        if (pulled.startsWith('ERROR')) {
          needsAdb = true;
          continue;
        }
        path = pulled;
      } else {
        path = pathOf(v.uri);
      }
      if (path == null) continue;
      var size = v.sizeBytes;
      if (size <= 0) {
        try {
          size = await File(path).length();
        } catch (e) {
          if (kDebugMode) debugPrint('bulk_actions.size: $e');
        }
      }
      files.add(SharedFile(
        id: '${path.hashCode}',
        path: path,
        displayName: v.title.isNotEmpty ? v.title : p.basename(path),
        sizeBytes: size,
      ));
    }

    if (files.isEmpty) {
      AppSnackbar.global(needsAdb ? s.connectAdbToSend : s.selectionNoFiles);
      return false;
    }
    ref.read(transferProvider.notifier).addFiles(files);
    // Tab 2 is Transfer in Send mode. Setting the shell index AND navigating
    // is what the in-player action does; doing only one leaves the tab bar and
    // the visible page disagreeing.
    ref.read(shellTabIndexProvider.notifier).state = 2;
    if (!context.mounted) return true;
    context.go(Routes.transfer);
    return true;
  }

  // ── Hide (Recycle Bin) ─────────────────────────────────────────────────

  static Future<bool> hide(
    BuildContext context,
    WidgetRef ref, {
    required List<Video> videos,
  }) async {
    final s = AppStrings.of(context);
    final bin = ref.read(recycleBinProvider.notifier);
    var hidden = 0;
    for (final v in videos) {
      await bin.add(
            RecycleBinEntry(
              videoUri: v.uri,
              videoTitle: v.title,
              folderPath: v.folderPath,
              deletedAt: DateTime.now(),
              sizeBytes: v.sizeBytes,
            ),
          );
      hidden++;
    }
    // NO `ref.invalidate(allVideosProvider)` HERE.
    //
    // It looks like the obvious way to make the list refresh, and it is the
    // expensive wrong one: it discards the cached library and re-queries
    // MediaStore for every video on the device. The exclusion added in
    // v1.56.1 WATCHES `recycleBinProvider`, so writing to the bin already
    // rebuilds every list that depends on it — instantly, from data already
    // in memory. Invalidating on top of that turns a free update into a full
    // rescan on a phone that may hold thousands of files.
    AppSnackbar.global('$hidden · ${s.selectionHidden}');
    return true;
  }

  // ── Rebuild thumbnails ─────────────────────────────────────────────────

  static Future<bool> rebuildThumbnails(
    BuildContext context,
    WidgetRef ref, {
    required List<Video> videos,
  }) async {
    final s = AppStrings.of(context);
    final paths = <String>[];
    for (final v in videos) {
      final path = pathOf(v.uri);
      if (path != null) paths.add(path);
    }
    await ThumbnailCache.instance.invalidateAll(paths);
    // A rescan IS needed here, unlike Hide: nothing observable changed in any
    // provider, so without it the tiles keep painting the frames they already
    // hold and the user sees no rebuild at all. The cost is accepted because
    // this is an explicit, rarely-used action rather than a side effect.
    ref.invalidate(allVideosProvider);
    AppSnackbar.global(s.selectionRebuilt);
    return true;
  }

  // ── Share ──────────────────────────────────────────────────────────────

  /// Share the FILES, not their paths — a path string means nothing to the
  /// app receiving it.
  static Future<bool> share(
    BuildContext context,
    WidgetRef ref, {
    required List<Video> videos,
  }) async {
    final s = AppStrings.of(context);
    final files = <XFile>[];
    // Bounded. Handing a share sheet several hundred files is how it stops
    // responding, and nobody means to share four hundred videos at once.
    for (final v in videos.take(50)) {
      final path = pathOf(v.uri);
      if (path != null) files.add(XFile(path));
    }
    if (files.isEmpty) {
      AppSnackbar.global(s.selectionNoFiles);
      return false;
    }
    try {
      await Share.shareXFiles(files);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('bulk_actions.share: $e');
      AppSnackbar.globalError(s.shareFailed);
      return false;
    }
  }

  // ── Properties ─────────────────────────────────────────────────────────

  /// Totals for the selection: how many, how big, how long.
  ///
  /// The old bulk "Properties" showed the count and nothing else — a number
  /// the title bar was already showing. Size and total duration are the two
  /// things somebody actually wants before moving a batch onto a card or
  /// deciding whether it fits.
  static Future<bool> properties(
    BuildContext context,
    WidgetRef ref, {
    required List<Video> videos,
  }) async {
    final s = AppStrings.of(context);
    var bytes = 0;
    var duration = Duration.zero;
    final folders = <String>{};
    for (final v in videos) {
      bytes += v.sizeBytes;
      duration += v.duration;
      folders.add(v.folderPath);
    }
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title:
            Text(s.properties, style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _row(s.videos, '${videos.length}'),
            _row(s.folders, '${folders.length}'),
            _row(s.size, _bytes(bytes)),
            _row(s.duration, _hms(duration)),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(s.close,
                style: const TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
    return true;
  }

  static Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(label,
                style: const TextStyle(
                    color: AppColors.darkOnSurfaceMuted, fontSize: 13)),
            const SizedBox(width: 24),
            Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      );

  static String _bytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }

  static String _hms(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$sec' : '$m:$sec';
  }
}
