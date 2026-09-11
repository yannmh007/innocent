import 'package:flutter/foundation.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/ui/app_snackbar.dart';
import '../../../../core/services/private_folder/private_folder_service.dart';
import '../../../../core/services/biometric/biometric_service.dart';
import '../../../../core/di/core_providers.dart';
import '../../../../core/services/subtitles/subtitle_download_service.dart';
import '../../../transfer/presentation/transfer_screen.dart';
import '../../../../core/services/file_transfer/file_transfer_service.dart';
import '../../../user_data/domain/user_data_models.dart';
import '../../../private_folder/data/private_folder_providers.dart';
import '../library_provider.dart';
import '../../../user_data/user_data_providers.dart';
import '../../../../core/services/preferences/player_settings_service.dart';
import '../../domain/video.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/services/thumbnail/thumbnail_cache.dart';
import 'media_identity_migrator.dart';
import '../../../../core/services/subtitles/subtitle_formats.dart';
class _OptionItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;
  const _OptionItem(
    this.icon,
    this.label,
    this.onTap, {
    this.isDestructive = false,
  });
}

/// Video option menu — PDF page 3, with functional handlers.
///
/// Phase 38: All handlers now run against a STABLE [hostContext] (the screen
/// that opened the menu) instead of the bottom-sheet's own context. The
/// sheet's context becomes defunct the moment the sheet is popped, so any
/// follow-up `showDialog` / `Navigator.push` / `ScaffoldMessenger` call that
/// used it would either silently fail or throw. Confirmation toasts now use
/// the context-free [AppSnackbar.global] so they reliably appear AFTER the
/// sheet has closed (MX Player shows these toasts).
class VideoOptionMenu extends ConsumerWidget {
  final Video video;

  /// The screen context that opened this menu — stays mounted after the
  /// bottom sheet is dismissed, so it is safe for navigation/dialogs.
  final BuildContext hostContext;

  const VideoOptionMenu({
    super.key,
    required this.video,
    required this.hostContext,
  });

  static Future<void> show(BuildContext context, Video video) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      // Draggable sheet: opens partially (through "Rename") to avoid eating
      // the whole screen; the user drags up to reveal the rest. The body
      // uses a DraggableScrollableSheet + SafeArea so nothing is ever hidden
      // behind the phone's nav bar.
      isScrollControlled: true,
      builder: (_) => VideoOptionMenu(video: video, hostContext: context),
    );
  }

  /// Close the bottom sheet using its own (still-valid) context.
  void _dismiss(BuildContext sheetContext) {
    Navigator.of(sheetContext).pop();
  }

  Future<void> _addToWatchLater(BuildContext sheetContext, WidgetRef ref) async {
    final added =
        await ref.read(watchLaterProvider.notifier).add(video.uri);
    _dismiss(sheetContext);
    AppSnackbar.global(
        added ? '⏰ Added to Watch Later' : 'Already in Watch Later');
  }

  Future<void> _toggleFavourite(BuildContext sheetContext, WidgetRef ref) async {
    final added =
        await ref.read(favouritesProvider.notifier).toggle(video.uri);
    _dismiss(sheetContext);
    AppSnackbar.global(
        added ? '★ Added to favourites' : '☆ Removed from favourites');
  }

  Future<void> _addToPlaylist(BuildContext sheetContext, WidgetRef ref) async {
    // Open the picker ON TOP of this menu (sheet context still valid),
    // then dismiss this menu once the picker returns.
    final result = await showModalBottomSheet<String>(
      context: sheetContext,
      backgroundColor: AppColors.darkSurface,
      builder: (_) => _PlaylistPickerSheet(video: video),
    );
    if (sheetContext.mounted) _dismiss(sheetContext);
    if (result != null) AppSnackbar.global(result);
  }

  Future<void> _share(BuildContext sheetContext) async {
    _dismiss(sheetContext);
    try {
      await Share.share(video.uri, subject: video.title);
    } catch (e) {
      AppSnackbar.globalError('Share failed: $e');
    }
  }

  /// Phase 45 (audit): Search Subtitle online. MX Player V3 lets users
  /// hunt for subtitles by language from OpenSubtitles. We open a
  /// language picker dialog and surface a clear "coming soon" toast —
  /// the entry point and UX flow exist so users don't notice the
  /// difference until they actually try to download (then we explain
  /// the network integration is pending).
  /// Audit fix (standard high-quality): replace the stub
  /// "future update" message with a real, contained feature —
  /// **manual subtitle URL download**. The user pastes a direct
  /// link (e.g. raw .srt URL from OpenSubtitles, Subscene, a friend's
  /// shared folder) and we fetch it, validate it, and save it
  /// alongside the video so the player attaches it on next open.
  ///
  /// Honest scope: this is not the OpenSubtitles API integration —
  /// that needs a developer key + per-user account flow. Manual
  /// URLs are a real, useful subset that doesn't require external
  /// account setup.
  Future<void> _searchSubtitle(BuildContext sheetContext, WidgetRef ref) async {
    _dismiss(sheetContext);
    if (!hostContext.mounted) return;
    final urlCtl = TextEditingController();
    final result = await showDialog<String>(
      context: hostContext,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(sheetContext).addSubtitleFromUrl,
          style: const TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paste a direct link to a .srt / .ass / .vtt / .ssa / .sub file '
              'for "${video.title}".',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtl,
              autofocus: true,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'https://example.com/subtitle.srt',
                hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accentBlue),
                ),
              ),
              onSubmitted: (v) => Navigator.of(dctx).pop(v.trim()),
            ),
            const SizedBox(height: 12),
            Text(AppStrings.of(sheetContext).subtitleUrlTip,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(AppStrings.of(sheetContext).cancel,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dctx).pop(urlCtl.text.trim()),
            child: Text(AppStrings.of(sheetContext).download,
              style: const TextStyle(color: AppColors.accentBlue),
            ),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    if (!hostContext.mounted) return;
    // Show a progress snackbar so the user knows something's happening.
    ScaffoldMessenger.of(hostContext)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(
          children: [
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Text(AppStrings.of(sheetContext).downloadingSubtitle),
          ],
        ),
        duration: const Duration(seconds: 30),
        behavior: SnackBarBehavior.floating,
      ));
    try {
      final svc = ref.read(subtitleDownloadServiceProvider);
      final path = await svc.downloadFor(
        videoUri: video.uri,
        url: result,
      );
      if (!hostContext.mounted) return;
      ScaffoldMessenger.of(hostContext)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
              'Subtitle saved. Reopen the video to use it.\n${p.basename(path)}'),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ));
    } catch (e) {
      if (!hostContext.mounted) return;
      ScaffoldMessenger.of(hostContext)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('${AppStrings.of(sheetContext).downloadFailed}: $e'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ));
    }
  }

  Future<void> _moveToRecycleBin(
      BuildContext sheetContext, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: sheetContext,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(sheetContext).moveToBinTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(
          'This will hide "${video.title}" from your library. You can restore it from Recycle Bin later.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(AppStrings.of(sheetContext).cancel,
                style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(AppStrings.of(sheetContext).move,
                style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirm != true) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      return;
    }
    await ref.read(recycleBinProvider.notifier).add(
          RecycleBinEntry(
            videoUri: video.uri,
            videoTitle: video.title,
            folderPath: video.folderPath,
            deletedAt: DateTime.now(),
            sizeBytes: video.sizeBytes,
          ),
        );
    if (sheetContext.mounted) _dismiss(sheetContext);
    AppSnackbar.global('Moved to Recycle Bin');
  }

  Future<void> _showInfo(BuildContext sheetContext) async {
    // Show the info dialog on top, then close the menu afterwards.
    await VideoInfoDialog.show(sheetContext, video);
    if (sheetContext.mounted) _dismiss(sheetContext);
  }

  /// "Convert to Audio": extract the video's audio track to an .m4a saved
  /// under Innocent/Music/, showing a progress dialog. The heavy lifting is
  /// in [AudioExtractionService]; here we only resolve the on-disk path,
  /// drive the progress dialog, and report success/failure. Streaming
  /// (content:// / http) sources have no plain path, so we decline those
  /// cleanly rather than failing mid-encode.
  Future<void> _convertToAudio(BuildContext sheetContext, WidgetRef ref) async {
    final path = _resolveFilePath(video.uri);
    // Close the options sheet first — the progress dialog stands alone.
    _dismiss(sheetContext);
    if (path == null || !path.startsWith('/')) {
      AppSnackbar.global('This source has no local file to convert.');
      return;
    }
    final svc = ref.read(audioExtractionServiceProvider);
    if (svc.isBusy) {
      AppSnackbar.global('Another conversion is already running.');
      return;
    }

    // Use the root navigator's context (hostContext) for the dialog — the
    // sheet context is now defunct after _dismiss.
    final navContext = hostContext;
    var dialogOpen = false;
    if (navContext.mounted) {
      dialogOpen = true;
      showDialog<void>(
        context: navContext,
        barrierDismissible: false,
        builder: (_) => _AudioConvertProgressDialog(
          title: video.title,
          progress: svc.progress,
        ),
      );
    }

    final result = await svc.extract(
      videoPath: path,
      displayName: video.title,
    );

    // Dismiss the progress dialog if it's still up.
    if (dialogOpen && navContext.mounted) {
      Navigator.of(navContext, rootNavigator: true).pop();
    }

    if (result.success) {
      AppSnackbar.global('Saved to Innocent/Music');
    } else {
      AppSnackbar.global(result.error ?? 'Conversion failed.');
    }
  }

  // Sentinel distinguishing "user cancelled the folder chooser" from
  // "root selected" (null). A plain null would be ambiguous.
  static const String _kChooseCancelled = '__cancelled__';
  // Deliberate "Main folder" choice — distinct from a scrim dismissal
  // (which returns null) so the caller can tell them apart.
  static const String _kRootPick = '__root__';

  /// Bottom-sheet folder chooser for the lock flow: pick an existing
  /// organiser folder, the vault root, or create a new folder inline.
  /// Returns the chosen folderId (null = root) or [_kChooseCancelled].
  Future<String?> _chooseVaultFolder(
      BuildContext sheetContext, PrivateFolderService svc) async {
    final folders = await svc.loadFolders();
    if (!sheetContext.mounted) return _kChooseCancelled;
    final s = AppStrings.of(sheetContext);
    return showModalBottomSheet<String?>(
      context: sheetContext,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Text(s.chooseFolderTitle,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.home_outlined,
                          color: AppColors.accentBlue),
                      title: Text(s.mainFolderRoot,
                          style: const TextStyle(color: Colors.white)),
                      onTap: () => Navigator.of(sheetCtx).pop(_kRootPick),
                    ),
                    for (final f in folders)
                      ListTile(
                        leading: const Icon(Icons.folder,
                            color: AppColors.accentBlue),
                        title: Text(f.name,
                            style: const TextStyle(color: Colors.white)),
                        onTap: () => Navigator.of(sheetCtx).pop(f.id),
                      ),
                    const Divider(color: Colors.white12, height: 8),
                    ListTile(
                      leading: const Icon(Icons.create_new_folder_outlined,
                          color: AppColors.accentBlue),
                      title: Text(s.newFolderEllipsis,
                          style: const TextStyle(color: AppColors.accentBlue)),
                      onTap: () async {
                        final name = await _promptFolderName(sheetCtx);
                        if (name == null || name.trim().isEmpty) return;
                        final meta = await svc.createFolder(name.trim());
                        if (sheetCtx.mounted) {
                          Navigator.of(sheetCtx).pop(meta.id);
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    ).then((v) {
      // Scrim dismissal → null → cancelled. A real "Main folder" tap pops
      // the _kRootPick sentinel, which we translate back to a null
      // folderId (root) here.
      if (v == null) return _kChooseCancelled;
      if (v == _kRootPick) return null;
      return v;
    });
  }

  Future<String?> _promptFolderName(BuildContext ctx) {
    final c = TextEditingController();
    final s = AppStrings.of(ctx);
    return showDialog<String>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(s.createFolderTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: s.folderName,
            hintStyle: const TextStyle(color: AppColors.white40),
          ),
          onSubmitted: (_) => Navigator.of(dCtx).pop(c.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(c.text),
            child: Text(s.create),
          ),
        ],
      ),
    );
  }

  Future<void> _lockInPrivateFolder(
      BuildContext sheetContext, WidgetRef ref) async {
    // Resolved from `sheetContext` BEFORE any await.
    //
    // Two separate reasons, and the first one broke the build:
    //   * `VideoOptionMenu` is a ConsumerWidget, NOT a State, so there is no
    //     `context` field on the class. The only BuildContext in scope inside
    //     these methods is the one passed in.
    //   * `AppStrings.of` reads an inherited widget from that element, and
    //     after an await the element may be gone — the exact failure
    //     `sheetContext.mounted` is checked for below.
    final msgLocking = AppStrings.of(sheetContext).lockingNow;
    final msgMoved = AppStrings.of(sheetContext).movedToPrivate;
    final svc = ref.read(privateFolderServiceProvider);
    final hasPin = await svc.hasPin();
    if (!hasPin) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.global(
          'Set up Private Folder PIN first (Me → Private Folder)');
      return;
    }
    // v0.51 requirement: verify identity BEFORE locking, so a passer-by
    // can't move a file into the vault. If the device has biometric
    // enrolled we prompt for fingerprint/face; otherwise (or on failure)
    // the PIN screen inside Private Folder remains the gate.
    final bio = ref.read(biometricServiceProvider);
    if (await bio.canCheck()) {
      final ok = await bio.authenticate(
          reason: AppStrings.of(sheetContext).verifyToLock);
      if (!ok) {
        AppSnackbar.global(AppStrings.of(sheetContext).lockCancelled);
        return;
      }
    }

    // Then ask which organiser folder to drop it in (existing folder, the
    // root, or a brand-new folder created on the spot).
    final folderId = await _chooseVaultFolder(sheetContext, svc);
    if (folderId == _kChooseCancelled) {
      AppSnackbar.global(AppStrings.of(sheetContext).lockCancelled);
      return;
    }

    // Vaulting copies (then deletes) the file, which can take a moment
    // for a large video — show a brief progress note. The copy runs off
    // the UI isolate so the app stays responsive.
    AppSnackbar.global(msgLocking);
    try {
      final entry = await svc.importToVault(
        videoUri: video.uri,
        videoTitle: video.title,
        folderId: folderId,
      );
      // Refresh library so the video disappears from main lists.
      ref.invalidate(privateFolderUrisProvider);
      ref.invalidate(foldersProvider);
      ref.invalidate(allVideosProvider);
      // Erase every public trace of the now-private video: its Continue
      // Watching / history entry and any saved resume position. Without
      // this a stale entry keeps pointing at the (now deleted) original
      // file, so it shows in Continue Watching but can't be played.
      try {
        await ref.read(historyProvider.notifier).deleteEntry(video.uri);
        final resume = ref.read(resumeStorageProvider);
        await resume.clearPosition(video.uri);
        final last = await resume.getLastPlaying();
        if (last?.uri == video.uri) await resume.clearLastPlaying();
      } catch (e) { if (kDebugMode) debugPrint('video_option_menu.best-effort: $e'); }
      if (sheetContext.mounted) _dismiss(sheetContext);
      if (entry.isVaulted && entry.originalRemoved) {
        AppSnackbar.global(msgMoved);
      } else if (entry.isVaulted && !entry.originalRemoved) {
        // Copy succeeded but the original couldn't be deleted.
        AppSnackbar.global(
            '🔒 Secured, but the original could not be removed — '
            'grant All-files access to fully hide it.');
      } else {
        // content:// system-managed file → soft-hide fallback.
        AppSnackbar.global(
            '🔒 Hidden from library (system file — could not be moved)');
      }
    } catch (e) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.globalError('Lock failed: $e');
    }
  }

  /// Rename the video file on disk. Only works for file:// URIs.
  Future<void> _rename(BuildContext sheetContext, WidgetRef ref) async {
    // Resolved from `sheetContext` BEFORE any await.
    //
    // Two separate reasons, and the first one broke the build:
    //   * `VideoOptionMenu` is a ConsumerWidget, NOT a State, so there is no
    //     `context` field on the class. The only BuildContext in scope inside
    //     these methods is the one passed in.
    //   * `AppStrings.of` reads an inherited widget from that element, and
    //     after an await the element may be gone — the exact failure
    //     `sheetContext.mounted` is checked for below.
    final msgRenamed = AppStrings.of(sheetContext).renamedOk;
    final filePath = _resolveFilePath(video.uri);
    if (filePath == null) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.global("Can't rename this video (system-managed file)");
      return;
    }
    final originalName = p.basenameWithoutExtension(filePath);
    final ext = p.extension(filePath); // includes dot
    final dir = p.dirname(filePath);

    final newName = await showDialog<String>(
      context: sheetContext,
      builder: (ctx) => _RenameDialog(initial: originalName),
    );
    if (newName == null || newName.trim().isEmpty) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      return;
    }
    final trimmed = newName.trim();
    if (trimmed == originalName) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      return;
    }

    if (trimmed.contains('/') || trimmed.contains('\\')) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.global('Name cannot contain / or \\');
      return;
    }

    final newPath = p.join(dir, '$trimmed$ext');
    if (await File(newPath).exists()) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.global('A file with that name already exists');
      return;
    }
    try {
      await File(filePath).rename(newPath);
      // A rename changes the video's URI, and every piece of saved state is
      // keyed by it — resume position, history, favourite, playlist slots.
      // Renaming silently detached all of them, which is the same defect the
      // multi-select Move had: invisible now, discovered days later.
      await MediaIdentityMigrator.migrate(
        ref,
        oldUri: video.uri,
        newUri: Uri.file(newPath).toString(),
      );
      await ThumbnailCache.instance.invalidate(filePath);
      ref.invalidate(foldersProvider);
      ref.invalidate(allVideosProvider);
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.global(msgRenamed);
    } catch (e) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.globalError('Rename failed: $e');
    }
  }

  /// Permanently delete the video file from disk (after confirm).
  Future<void> _deletePermanent(
      BuildContext sheetContext, WidgetRef ref) async {
    // Resolved from `sheetContext` BEFORE any await.
    //
    // Two separate reasons, and the first one broke the build:
    //   * `VideoOptionMenu` is a ConsumerWidget, NOT a State, so there is no
    //     `context` field on the class. The only BuildContext in scope inside
    //     these methods is the one passed in.
    //   * `AppStrings.of` reads an inherited widget from that element, and
    //     after an await the element may be gone — the exact failure
    //     `sheetContext.mounted` is checked for below.
    final msgDeleted = AppStrings.of(sheetContext).deletedOk;
    final filePath = _resolveFilePath(video.uri);
    if (filePath == null) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.global("Can't delete this video (system-managed file)");
      return;
    }

    // Settings → General → "Allow editing". Off, the app must not modify or
    // remove the user's files at all — that is what the switch means, and it
    // is the one people turn off when they hand the phone to someone else.
    // It had no reader, so Delete worked regardless.
    if (!ref
        .read(playerSettingsProvider)
        .get(PlayerSetting.generalAllowEditing)) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.global(
          'Editing is turned off in Settings → General → Allow editing');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: sheetContext,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(sheetContext).deleteVideoTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(
          'Permanently delete "${video.title}"?\n\nThis cannot be undone.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppStrings.of(sheetContext).cancel,
                style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child:
                Text(AppStrings.of(sheetContext).delete, style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      return;
    }
    try {
      await File(filePath).delete();
      // Settings → General → "Delete subtitle files together". A sidecar
      // subtitle is useless once its video is gone, and leaving a stray .srt
      // behind is how a folder slowly fills with orphans — but deleting a file
      // the user did not name is exactly the kind of thing that needs to be a
      // choice, which is why the setting exists. It had no reader, so the
      // subtitles were always left behind.
      if (ref
          .read(playerSettingsProvider)
          .get(PlayerSetting.generalDeleteSubtitleFiles)) {
        await _deleteSidecarSubtitles(filePath);
      }
      ref.invalidate(foldersProvider);
      ref.invalidate(allVideosProvider);
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.global(msgDeleted);
    } catch (e) {
      if (sheetContext.mounted) _dismiss(sheetContext);
      AppSnackbar.globalError('Delete failed: $e');
    }
  }

  /// Remove subtitle files that sit beside [videoPath] and share its name.
  ///
  /// Only exact `name.ext` matches are touched — never `name.something.srt` or
  /// anything with a different stem. Deleting by prefix would be a good way to
  /// take out a neighbouring file that merely starts the same, and that is not
  /// a mistake anyone can undo.
  Future<void> _deleteSidecarSubtitles(String videoPath) async {
    // v1.63: the fifth and last copy of this list. It knew six formats while
    // the player knew four, so deleting a video could leave a `.idx`/`.mpl`
    // sidecar orphaned beside nothing. One list now.
    const exts = SubtitleFormats.allExtensions;
    final dot = videoPath.lastIndexOf('.');
    if (dot <= 0) return;
    final stem = videoPath.substring(0, dot);
    for (final e in exts) {
      try {
        final f = File('$stem.$e');
        if (await f.exists()) await f.delete();
      } catch (_) {
        // Read-only volume, or gone already. Losing the video is the operation
        // the user asked for; a leftover subtitle is not worth an error toast.
      }
    }
  }

  /// Convert a video URI to an on-disk file path if possible.
  String? _resolveFilePath(String uri) {
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFav = ref.watch(favouritesProvider).contains(video.uri);

    final items = [
      // Custom order (user-specified): the most-used actions first, so the
      // list can be cut off at "Rename" by default and the rest reached by
      // dragging the sheet up.
      _OptionItem(
        isFav ? Icons.favorite : Icons.favorite_outline,
        isFav ? 'Remove from favourites' : 'Favourite',
        () => _toggleFavourite(context, ref),
      ),
      _OptionItem(
        Icons.import_export,
        'File Transfer',
        () {
          _dismiss(context);
          // v0.50 fix: this action used to just OPEN the Transfer tab —
          // the tapped video never made it into the share list, so the
          // other phone got an empty page. Register the actual file
          // first (same mapping the picker uses), then navigate.
          final path = video.uri.startsWith('file://')
              ? Uri.parse(video.uri).toFilePath()
              : video.uri;
          ref.read(transferProvider.notifier).addFiles([
            SharedFile(
              id: '${path.hashCode}',
              path: path,
              displayName: video.title,
              sizeBytes: video.sizeBytes,
            ),
          ]);
          // Use the stable host context — the sheet context is now defunct.
          Navigator.of(hostContext).push(
            MaterialPageRoute(builder: (_) => const TransferScreen()),
          );
        },
      ),
      _OptionItem(
        Icons.lock_outline,
        'Lock in Private Folder',
        () => _lockInPrivateFolder(context, ref),
      ),
      _OptionItem(
        Icons.info_outline,
        'Properties',
        () => _showInfo(context),
      ),
      _OptionItem(
        Icons.share,
        'Share',
        () => _share(context),
      ),
      _OptionItem(
        Icons.audiotrack,
        'Convert to Audio',
        () => _convertToAudio(context, ref),
      ),
      _OptionItem(
        Icons.drive_file_rename_outline,
        'Rename',
        () => _rename(context, ref),
      ),
      // ── Everything below the fold: reached by dragging the sheet up. ──
      _OptionItem(
        Icons.playlist_add,
        'Add To Playlist',
        () => _addToPlaylist(context, ref),
      ),
      _OptionItem(
        Icons.watch_later_outlined,
        'Add to Watch Later',
        () => _addToWatchLater(context, ref),
      ),
      _OptionItem(
        Icons.subtitles_outlined,
        'Add Subtitle from URL',
        () => _searchSubtitle(context, ref),
      ),
      _OptionItem(
        Icons.delete_sweep_outlined,
        'Move to Recycle Bin',
        () => _moveToRecycleBin(context, ref),
        isDestructive: true,
      ),
      _OptionItem(
        Icons.delete_forever,
        'Delete',
        () => _deletePermanent(context, ref),
        isDestructive: true,
      ),
    ];

    // How many items to show before the fold. The sheet opens at a height
    // that reveals exactly these; the user drags up to see the rest.
    const kInitialVisibleCount = 7; // …through "Rename"

    // Height math so the sheet opens showing exactly the first
    // [kInitialVisibleCount] rows plus the header, and can be dragged up to
    // reveal the rest. Computed as a fraction of the available height so it
    // adapts to both portrait and landscape.
    final media = MediaQuery.of(context);
    final screenH = media.size.height;
    final bottomInset = media.padding.bottom; // nav-bar / gesture inset
    const rowH = 50.0; // InkWell row (14*2 padding + 22 icon ≈ 50)
    const headerH = 92.0; // handle + title + divider
    final totalContentH =
        headerH + rowH * items.length + bottomInset + 8;
    final initialContentH =
        headerH + rowH * kInitialVisibleCount + bottomInset + 8;
    // Clamp fractions into the sheet's valid 0..1 range.
    double frac(double px) => (px / screenH).clamp(0.20, 0.92);
    final maxFrac = frac(totalContentH);
    // Initial never exceeds max (small phone / few items → they all fit).
    final initialFrac = initialContentH >= totalContentH
        ? maxFrac
        : frac(initialContentH).clamp(0.20, maxFrac);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: initialFrac,
      minChildSize: (initialFrac * 0.6).clamp(0.20, initialFrac),
      maxChildSize: maxFrac,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.darkSurface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Pinned header (drag handle + title). Not part of the scroll
              // so it stays visible as the user drags/scrolls the list.
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  video.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              // The options. This ListView is driven by the sheet's own
              // scrollController, so dragging the sheet and scrolling the
              // list are unified: a drag past the top expands the sheet,
              // and once expanded the list scrolls. The bottom padding
              // clears the phone's nav bar so the last row (Delete) is
              // always tappable, never hidden behind Home/Back.
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  padding: EdgeInsets.only(bottom: bottomInset + 8),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return InkWell(
                      onTap: item.onTap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                        child: Row(
                          children: [
                            Icon(
                              item.icon,
                              color: item.isDestructive
                                  ? AppColors.error
                                  : Colors.white,
                              size: 22,
                            ),
                            const SizedBox(width: 20),
                            Text(
                              item.label,
                              style: TextStyle(
                                color: item.isDestructive
                                    ? AppColors.error
                                    : Colors.white,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Bottom sheet for picking a playlist (or creating one) to add a video to.
class _PlaylistPickerSheet extends ConsumerStatefulWidget {
  final Video video;
  const _PlaylistPickerSheet({required this.video});

  @override
  ConsumerState<_PlaylistPickerSheet> createState() =>
      _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState extends ConsumerState<_PlaylistPickerSheet> {
  Future<void> _showCreateDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).newPlaylistTitle,
            style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(AppStrings.of(context).cancel,
                style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(controller.text.trim()),
            child: Text(AppStrings.of(context).create,
                style: const TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final playlist = await ref.read(playlistsProvider.notifier).create(name);
    await ref
        .read(playlistsProvider.notifier)
        .addVideo(playlist.id, widget.video.uri);
    if (!mounted) return;
    Navigator.of(context).pop('Added to "$name"');
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(AppStrings.of(context).addToPlaylist,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          if (playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(AppStrings.of(context).noPlaylistsYet,
                style: const TextStyle(color: Colors.white54),
              ),
            ),
          ...playlists.map(
            (pl) => ListTile(
              leading: const Icon(Icons.playlist_play, color: Colors.white),
              title:
                  Text(pl.name, style: const TextStyle(color: Colors.white)),
              subtitle: Text(
                '${pl.videoUris.length} videos',
                style: const TextStyle(
                    color: AppColors.darkOnSurfaceMuted, fontSize: 12),
              ),
              onTap: () async {
                await ref
                    .read(playlistsProvider.notifier)
                    .addVideo(pl.id, widget.video.uri);
                if (!mounted) return;
                Navigator.of(context).pop('Added to "${pl.name}"');
              },
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          ListTile(
            leading: const Icon(Icons.add, color: AppColors.accentBlue),
            title: Text(AppStrings.of(context).createNewPlaylist,
              style: const TextStyle(
                color: AppColors.accentBlue,
                fontWeight: FontWeight.w500,
              ),
            ),
            onTap: _showCreateDialog,
          ),
        ],
      ),
    );
  }
}

/// Video information dialog — shows metadata.
/// Rich "Properties / Information" dialog. Public + with a [show] helper so
/// both the library's Properties action and the in-player Information button
/// present the exact same detailed view (file, media, playback history).
class VideoInfoDialog extends ConsumerStatefulWidget {
  final Video video;
  /// When shown from inside the video player, a translucent scrim looks
  /// better over the moving picture than the default opaque barrier.
  final bool overPlayer;
  const VideoInfoDialog({super.key, required this.video, this.overPlayer = false});

  /// Show the dialog. [overPlayer] lightens the barrier so the video stays
  /// faintly visible behind it (used from the player's Information button).
  static Future<void> show(
    BuildContext context,
    Video video, {
    bool overPlayer = false,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: overPlayer ? Colors.black38 : Colors.black54,
      builder: (_) => VideoInfoDialog(video: video, overPlayer: overPlayer),
    );
  }

  @override
  ConsumerState<VideoInfoDialog> createState() => _VideoInfoDialogState();
}

class _VideoInfoDialogState extends ConsumerState<VideoInfoDialog> {
  // Loaded asynchronously so the dialog paints instantly and fills in the
  // richer fields (exact bytes, absolute path, last-modified, playback
  // position) as they resolve. Nothing here blocks the UI thread.
  bool _loading = true;
  String? _absPath;
  int? _exactBytes;
  DateTime? _modified;
  Duration? _lastPosition;

  Video get video => widget.video;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String? absPath;
    int? bytes;
    DateTime? modified;
    Duration? lastPos;
    try {
      // Resolve the on-disk path from the (possibly content://) uri.
      final svc = ref.read(privateFolderServiceProvider);
      absPath = svc.resolveFilePath(video.uri);
      if (absPath != null) {
        final f = File(absPath);
        if (await f.exists()) {
          final st = await f.stat();
          bytes = st.size;
          modified = st.modified;
        }
      }
    } catch (_) {}
    try {
      lastPos = await ref.read(resumeStorageProvider).getPosition(video.uri);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _absPath = absPath;
        _exactBytes = bytes;
        _modified = modified;
        _lastPosition = lastPos;
        _loading = false;
      });
    }
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// "829 MB (828,943,837 bytes)" — MX Player style.
  String _fmtSizeExact(int bytes) {
    final grouped = bytes.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    return '${_fmtSize(bytes)} ($grouped bytes)';
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _fmtDateTime(DateTime? dt) {
    if (dt == null) return '—';
    final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final mm = dt.minute.toString().padLeft(2, '0');
    final ap = dt.hour < 12 ? 'AM' : 'PM';
    return '${_months[dt.month - 1]} ${dt.day}, ${dt.year} at $h12:$mm $ap';
  }

  /// Estimated overall bit rate from size + duration (kbps). MX Player
  /// shows per-stream bit rates from the container; we don't parse the
  /// container, so we present a single honest estimate labelled as such.
  String? _estimatedBitrate() {
    final bytes = _exactBytes ?? video.sizeBytes;
    final secs = video.duration.inSeconds;
    if (bytes <= 0 || secs <= 0) return null;
    final kbps = (bytes * 8) / secs / 1000;
    if (kbps >= 1000) {
      return '${(kbps / 1000).toStringAsFixed(2)} Mbps';
    }
    return '${kbps.toStringAsFixed(0)} kbps';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final fileName = () {
      if (_absPath != null) return p.basename(_absPath!);
      try {
        final raw = Uri.parse(video.uri).pathSegments.lastOrNull ?? video.title;
        return raw.isEmpty ? video.title : raw;
      } catch (_) {
        return video.title;
      }
    }();
    final location = _absPath != null ? p.dirname(_absPath!) : video.folderPath;
    final fmt = video.mimeType?.split('/').lastOrNull?.toUpperCase();
    final sizeStr = _exactBytes != null
        ? _fmtSizeExact(_exactBytes!)
        : _fmtSize(video.sizeBytes);
    final bitrate = _estimatedBitrate();

    return Dialog(
      backgroundColor: AppColors.darkSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title = file name (MX Player uses the name as the heading).
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Text(
                fileName,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Flexible(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── File ──
                    _SectionHeader(s.propSectionFile),
                    _InfoRow(s.propFile, fileName),
                    _InfoRow(s.propLocation, location),
                    _InfoRow(s.propSize, sizeStr),
                    _InfoRow(s.propDate, _fmtDateTime(_modified ?? video.dateAdded)),
                    const SizedBox(height: 14),
                    // ── Media ──
                    _SectionHeader(s.propSectionMedia),
                    if (fmt != null && fmt.isNotEmpty)
                      _InfoRow(s.propFormat, fmt),
                    _InfoRow(s.propResolution,
                        '${video.width} x ${video.height}'),
                    _InfoRow(s.propLength, _fmtDuration(video.duration)),
                    if (bitrate != null)
                      _InfoRow(s.propBitrate, bitrate),
                    const SizedBox(height: 14),
                    // ── Playback history ──
                    _SectionHeader(s.propSectionPlayback),
                    _InfoRow(
                      s.propFinished,
                      _lastPosition == null
                          ? s.propFinishedYes
                          : s.propFinishedNo,
                    ),
                    if (_lastPosition != null)
                      _InfoRow(s.propLastPosition,
                          _fmtDuration(_lastPosition!)),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    s.okay,
                    style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small section header inside the properties dialog (File / Media /
/// Playback history), matching MX Player's grouped layout.
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        label,
        style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.darkOnSurfaceMuted,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
              ),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// Rename dialog — text input pre-filled with current filename (no ext).
class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.darkSurface,
      title: Text(AppStrings.of(context).rename, style: const TextStyle(color: Colors.white)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'New name',
          hintStyle: const TextStyle(color: Colors.white38),
          filled: true,
          fillColor: AppColors.darkSurfaceVariant,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppStrings.of(context).cancel,
              style: const TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(AppStrings.of(context).rename,
            style: const TextStyle(
              color: AppColors.accentBlue,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Phase 45 (audit): visual language chip used inside the Search Subtitle
/// dialog. Tapping doesn't do anything yet (subtitle download API is a
/// future phase) but the visual presence matches MX Player's flow.


/// Modal progress dialog shown while an audio extraction runs. Listens to the
/// service's [ValueNotifier] so the bar advances live; shows an indeterminate
/// spinner until the first real fraction arrives, then a percentage.
class _AudioConvertProgressDialog extends StatelessWidget {
  final String title;
  final ValueListenable<double?> progress;
  const _AudioConvertProgressDialog({
    required this.title,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Block the back button while converting so the dialog can only be
      // dismissed by the caller when extraction finishes — keeps the
      // dismiss logic deterministic.
      canPop: false,
      child: Dialog(
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.audiotrack,
                      color: AppColors.accentBlue, size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Converting to Audio',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.darkOnSurfaceMuted, fontSize: 13),
              ),
              const SizedBox(height: 18),
              ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (context, value, _) {
                  final pct = value == null ? null : (value * 100).round();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: value, // null → indeterminate
                          minHeight: 6,
                          backgroundColor: AppColors.white10,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              AppColors.accentBlue),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        pct == null ? 'Preparing…' : '$pct%',
                        style: const TextStyle(
                            color: AppColors.darkOnSurfaceMuted, fontSize: 12),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
