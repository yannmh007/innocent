import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/services/private_folder/private_folder_service.dart';
import '../../../core/di/core_providers.dart';
import '../../user_data/user_data_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../local_browser/domain/folder.dart';
import '../../local_browser/domain/video.dart';
import '../../local_browser/presentation/hidden_badge.dart';
import '../../local_browser/presentation/library_provider.dart';
import '../data/picker_media_source.dart';
import '../data/picker_providers.dart';
import '../../../core/services/adb/adb_service.dart';
import '../../../core/ui/adb_required_dialog.dart';
import '../../settings/presentation/adb_connect_screen.dart';
import 'package:photo_manager/photo_manager.dart';
import 'picker_sort_dialog.dart';
import 'vault_progress.dart';
import '../../../core/di/core_providers.dart';

import '../../../core/localization/app_strings.dart';

// === Add Files flow spec (innocent_add_files_flow_spec, v0.50) ===
// One full-screen route. A category strip (Videos · Images · Audio ·
// Files · Apps) sits under the app bar — the Zapya-style picker — and
// each category keeps the original two-level browse:
//   • root  → folder list (tap navigates in, no checkboxes)
//   • inside → item list (multi-select) + "Add Now"
// "Files" is a real directory browser (any depth, every file type) and
// "Apps" lists installed user apps whose APKs can be shared.
// Selection survives category switches; ✕ dismisses the whole picker.
const double _kFolderThumb = 63.0;
const double _kFolderRowExtent = 72.0;
const double _kFileThumbW = 95.0;
const double _kFileThumbH = 54.0;
const double _kFileThumbR = 5.0;

/// A single item chosen in the picker, already reduced to what every
/// consumer needs: a readable on-disk path + display name + size.
class PickedFile {
  final String path;
  final String name;
  final int sizeBytes;

  /// Creation time in epoch-ms (0 when unknown). Used by the Date sort.
  final int dateMs;
  const PickedFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    this.dateMs = 0,
  });
}

enum _Cat { videos, images, audio, files, apps }

/// One row of the Files browser with its metadata already fetched.
///
/// The picker used to call `statSync()` inside the sort comparator and again
/// for every visible row, so opening a folder with a few hundred files did
/// hundreds of blocking disk reads on the UI thread — the folder appeared to
/// hang, and a tap landing during that window could wedge the screen. Reading
/// size/date once, asynchronously, into this little value object keeps the
/// build path completely free of I/O.
class _DirEntry {
  const _DirEntry({
    required this.path,
    required this.name,
    required this.isDir,
    required this.sizeBytes,
    required this.dateMs,
    this.adbSrcPath,
  });

  final String path;
  final String name;
  final bool isDir;
  final int sizeBytes;
  final int dateMs;

  /// When non-null, this entry lives inside Android/data and was listed over
  /// ADB; [adbSrcPath] is its real device path. Files carry it so the picker
  /// can hand back an "adb://<path>" uri (pulled to a local copy on commit);
  /// directories carry it so tapping in continues the ADB listing.
  final String? adbSrcPath;
}

/// True when a picked path is one normal galleries hide — a dot-file or a
/// folder on the path whose name starts with a dot. Shown with a small badge
/// so the user knows they're pulling from a hidden location.
bool _pickHidden(String path, String name) {
  if (name.startsWith('.')) return true;
  for (final seg in path.split('/')) {
    if (seg.length > 1 && seg.startsWith('.')) return true;
  }
  return false;
}

const Set<String> _kImageExts = {
  '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif'
};
const Set<String> _kAudioExts = {
  '.mp3', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.opus', '.wma', '.amr'
};
const Set<String> _kVideoExts = {
  '.mp4', '.mkv', '.webm', '.mov', '.avi', '.3gp', '.m4v', '.ts', '.flv',
  '.wmv'
};

/// Full-screen "Select Files To Add" picker.
///
/// By default it commits the selection to the Private Folder via
/// [PrivateFolderService.importToVault] (any file type — the vault is
/// format-agnostic); alternatively a caller can pass [onCommit] to receive
/// the picked files instead (e.g. the Transfer tab) and/or a custom
/// [title]. Pops `true` when one or more files were handled.
class AddFilesPicker extends ConsumerStatefulWidget {
  /// Used only by the default (Private Folder) commit path. May be null
  /// when [onCommit] is supplied.
  final PrivateFolderService? service;

  /// When provided, the picker calls this with the selected files instead
  /// of importing them to the vault, then pops.
  final Future<void> Function(List<PickedFile> picked)? onCommit;

  /// App-bar title. Defaults to the Private Folder wording.
  final String title;

  /// When importing to the vault (default path), the organiser folder the
  /// new entries should land in. null = vault root. Ignored when
  /// [onCommit] is supplied.
  final String? targetFolderId;

  const AddFilesPicker({
    super.key,
    this.service,
    this.onCommit,
    this.title = 'Select Files To Add',
    this.targetFolderId,
  });

  @override
  ConsumerState<AddFilesPicker> createState() => _AddFilesPickerState();
}

class _AddFilesPickerState extends ConsumerState<AddFilesPicker> {
  _Cat _cat = _Cat.videos;

  // Videos (library providers)
  Folder? _vFolder;

  // Images / Audio — resolved instantly via MediaStore (photo_manager),
  // the same index the Videos tab uses.
  PickerMediaFolder? _mFolder;

  // Android/data media (Images/Audio tabs): when the user taps the special
  // "Android/data" bucket, this holds the ADB-scanned files of the current
  // media type. Null = showing the normal MediaStore folder list.
  Future<List<PickedFile>>? _adbMediaFiles;
  bool _adbMediaConnected = false;
  // Session cache of the ADB media scan per type, keyed by PickerAssetType.
  // The scan is a shell `find` over ADB (slow), so re-entering the Android/data
  // bucket reuses the first result instead of re-scanning every tap — matching
  // how the Files browser caches its ADB directory listings.
  final Map<PickerAssetType, Future<List<PickedFile>>> _adbMediaCache = {};

  // Null until first checked; false → show a "grant access" panel instead
  // of a bare empty state for Images/Audio.
  bool? _mediaPermission;

  // Sort/layout, shared across categories (v0.50.4). Default: newest first.
  PickerViewPrefs _view = const PickerViewPrefs();

  // Files tab: whether "All files access" is granted. On Android 11+ raw
  // dart:io file listing is blocked without it (folders still enumerate,
  // but File entries are hidden — the "folders show, files don't" bug).
  bool? _fullStorage;

  // Monotonic token: bumped whenever the visible category/level changes.
  // Async loaders capture it and drop their result if it's stale, so a
  // scan that finishes after the user has navigated away can never call
  // setState on content that's no longer shown (the old blank-screen bug).
  int _loadToken = 0;

  // Files (directory browser). Empty stack = storage-roots level.
  final List<Directory> _dirStack = [];

  // v0.94: "Show hidden" in the Files browser. When on, dot-folders/files show,
  // and tapping into Android/data/obb routes to the ADB screen if iADB isn't
  // connected (those folders are only readable through iADB).
  bool _showHidden = false;

  // v0.94: memoised directory listing. `_listKey` identifies the
  // (directory, sort, direction, hidden) combination the cached future belongs
  // to, so build() can reuse it instead of restarting the read every rebuild.
  String _listKey = '';
  Future<List<_DirEntry>>? _listFuture;
  // Per-path listing cache (keyed by the same path|sort|dir|hidden key). ADB
  // listings are slower than dart:io, so caching each visited directory means
  // navigating back UP a deep Android/data tree is instant instead of
  // re-fetching every level. Cleared wholesale by _invalidateListing (after a
  // connect) and bounded so it can't grow without limit.
  final Map<String, Future<List<_DirEntry>>> _listCache = {};

  // Cross-category selection: path → item.
  final Map<String, PickedFile> _picked = {};

  /// Which category each picked file came from, so the strip can show where
  /// a selection is currently hiding. Keyed identically to [_picked] and
  /// mutated only alongside it — see [_toggle].
  final Map<String, _Cat> _pickedCat = {};

  /// Scroll + per-chip keys for the category strip, so the active chip can
  /// be brought into view rather than left off the right edge.
  final ScrollController _catScroll = ScrollController();
  final Map<_Cat, GlobalKey> _catKeys = {
    for (final c in _Cat.values) c: GlobalKey(),
  };
  bool _adding = false;

  // ── selection helpers ─────────────────────────────────────────────
  @override
  void dispose() {
    _catScroll.dispose();
    super.dispose();
  }

  void _toggle(PickedFile f, bool? on) {
    setState(() {
      if (on ?? false) {
        _picked[f.path] = f;
        _pickedCat[f.path] = _cat;
      } else {
        _picked.remove(f.path);
        _pickedCat.remove(f.path);
      }
    });
  }

  /// How many currently-picked files came from [c].
  int _pickedIn(_Cat c) {
    var n = 0;
    for (final v in _pickedCat.values) {
      if (v == c) n++;
    }
    return n;
  }

  /// Bring the active chip fully into view.
  ///
  /// Without this the strip is genuinely broken on a narrow phone: five
  /// chips overflow 360dp, so a user whose category is Apps sees a strip
  /// with no visible selection at all.
  void _revealActiveChip() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _catKeys[_cat]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        // Keeps a sliver of the neighbouring chip on screen, which is what
        // tells the eye the strip continues.
        alignment: 0.5,
      );
    });
  }

  // ── navigation ────────────────────────────────────────────────────
  void _switchCat(_Cat c) {
    if (c == _cat) return;
    HapticFeedback.selectionClick();
    _revealActiveChip();
    setState(() {
      _loadToken++;
      _cat = c;
      _vFolder = null;
      _mFolder = null;
      _adbMediaFiles = null;
      _dirStack.clear();
      // A query typed against Videos means nothing in Apps, and leaving it set
      // makes the new category look empty for a reason nothing on screen
      // explains. `_rendered` is cleared with it so "select all" cannot act on
      // a list that is no longer displayed.
      _query = '';
      _searching = false;
      _rendered = const <PickedFile>[];
    });
    switch (c) {
      case _Cat.images:
      case _Cat.audio:
        // Folder lists come from app-lifetime FutureProviders now, so
        // there's nothing to kick off — the second visit is instant.
        _refreshMediaPermission();
        // Surface the "Android/data" bucket if iADB is connected, so app-data
        // images/audio can be browsed too (MediaStore never indexes them).
        _refreshAdbMediaConnected();
        break;
      case _Cat.files:
        _refreshFullStorage();
        break;
      case _Cat.apps:
      case _Cat.videos:
        break;
    }
  }

  /// Update whether the Android/data media bucket should show (iADB connected).
  Future<void> _refreshAdbMediaConnected() async {
    final connected = await AdbRequiredDialog.isConnected();
    if (!mounted) return;
    if (connected != _adbMediaConnected) {
      setState(() {
        _adbMediaConnected = connected;
        // Connection state changed → drop any cached ADB media scan so a
        // reconnect re-scans fresh and a disconnect doesn't serve stale paths.
        _adbMediaCache.clear();
      });
    }
  }

  Future<void> _refreshMediaPermission() async {
    // Probe the CURRENT tab's specific media type — image access and audio
    // access are separate grants on Android 13+, so a blanket check would
    // wrongly report "granted" when only video was ever allowed.
    final type = _cat == _Cat.audio
        ? PickerAssetType.audio
        : PickerAssetType.image;
    final ok = await PickerMediaSource.hasPermission(type);
    if (mounted) setState(() => _mediaPermission = ok);
  }

  Future<void> _refreshFullStorage() async {
    final ok =
        await ref.read(permissionServiceProvider).hasFullStorageAccess();
    if (mounted) setState(() => _fullStorage = ok);
  }

  Future<void> _requestFullStorage() async {
    await ref.read(permissionServiceProvider).requestFullStorageAccess();
    final ok =
        await ref.read(permissionServiceProvider).hasFullStorageAccess();
    if (!mounted) return;
    ref.invalidate(pickerStorageRootsProvider);
    if (mounted) {
      setState(() {
        _fullStorage = ok;
        _dirStack.clear();
      });
    }
  }

  Widget _storageAccessPanel() {
    final s = AppStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_special_outlined,
                color: AppColors.white40, size: 56),
            const SizedBox(height: 16),
            Text(s.allFilesAccessNeeded,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(s.allFilesAccessHint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 13, height: 1.4)),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
              ),
              onPressed: _requestFullStorage,
              child: Text(s.grantAccess,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _requestMediaPermission() async {
    final type = _cat == _Cat.audio
        ? PickerAssetType.audio
        : PickerAssetType.image;
    // A real query triggers the OS prompt for THIS type's granular
    // permission (READ_MEDIA_IMAGES / _AUDIO on Android 13+).
    final before = await PickerMediaSource.hasPermission(type);
    if (!before) {
      await PickerMediaSource.folders(type);
    }
    final after = await PickerMediaSource.hasPermission(type);
    // Still denied after the prompt → the user must enable it in Settings
    // (they may have picked "Don't allow" / limited access).
    if (!after) {
      await PhotoManager.openSetting();
    }
    if (!mounted) return;
    setState(() {
      _mediaPermission = after;
      // Recompute both cached lists now that access may have changed.
      ref.invalidate(pickerImageFoldersProvider);
      ref.invalidate(pickerAudioFoldersProvider);
    });
  }

  Widget _permissionPanel() {
    final s = AppStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.perm_media_outlined,
                color: AppColors.white40, size: 56),
            const SizedBox(height: 16),
            Text(s.mediaPermissionNeeded,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(s.mediaPermissionHint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 13, height: 1.35)),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
              ),
              onPressed: _requestMediaPermission,
              child: Text(s.grantAccess,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  void _popLevel() {
    setState(() {
      _loadToken++;
      // Same reason as [_openDir]: the list about to be shown is not the one
      // `_rendered` still holds.
      _rendered = const <PickedFile>[];
      switch (_cat) {
        case _Cat.videos:
          _vFolder = null;
          break;
        case _Cat.images:
        case _Cat.audio:
          _mFolder = null;
          break;
        case _Cat.files:
          _dirStack.clear();
          break;
        case _Cat.apps:
          break;
      }
    });
  }

  // ── data sources ──────────────────────────────────────────────────
  /// All mounted storage volumes: primary shared storage plus any
  /// removable /storage/XXXX-XXXX SD cards.

  // ── commit ────────────────────────────────────────────────────────
  /// Bytes as something a person can read. Local rather than shared: the
  /// picker has no formatter of its own and one number in a snackbar does not
  /// justify a new dependency between two features.
  static String _fmtBytes(int b) {
    if (b >= 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).round()} MB';
    if (b >= 1024) return '${(b / 1024).round()} KB';
    return '$b B';
  }

  Future<void> _commit() async {
    if (_picked.isEmpty || _adding) return;
    setState(() => _adding = true);
    final picked = _picked.values.toList();
    final onCommit = widget.onCommit;
    // Wrapped so a failure anywhere below still releases _adding — otherwise
    // the Add button stays disabled and the sheet looks frozen.
    try {
      if (onCommit != null) {
      try {
        await onCommit(picked);
      } catch (e) {
        if (kDebugMode) debugPrint('add_files_picker.commit: $e');
      }
    } else {
      final svc = widget.service;
      if (svc != null) {
        // ─── SPACE CHECK, BEFORE THE FIRST BYTE MOVES ──────────────────────
        //
        // Vaulting COPIES each file into app-internal storage. Selecting 20 GB
        // with 5 GB free used to start anyway: the loop copied until the disk
        // filled, then every remaining file failed one at a time, leaving a
        // half-vaulted set on a full device.
        //
        // That failure is worse than it sounds. The whole reason to vault a
        // file is to hide it, and a user who believes a file is hidden may
        // delete the original. A run that half-succeeds while reporting
        // per-file errors is exactly the state in which that happens.
        //
        // The Transfer receiver has refused up front for the same reason since
        // a Wi-Fi batch once filled a disk on its last file. The vault had the
        // identical exposure and no guard - this closes the gap with the same
        // control rather than a new one.
        //
        // 64 MB of headroom, matching the receiver: a volume driven to exactly
        // zero misbehaves in ways that have nothing to do with this app.
        var needed = 0;
        for (final f in picked) {
          needed += f.sizeBytes;
        }
        if (needed > 0) {
          final free = await svc.freeSpaceBytes();
          // free < 0 means the platform would not say. Proceeding is right:
          // refusing on an unknown would block every import on any device
          // whose answer we cannot read.
          if (free >= 0 && free < needed + (64 * 1024 * 1024)) {
            if (!mounted) {
              setState(() => _adding = false);
              return;
            }
            final s = AppStrings.of(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${s.notEnoughSpace} '
                  '(${_fmtBytes(needed)} / ${_fmtBytes(free)})',
                ),
                duration: const Duration(seconds: 5),
              ),
            );
            setState(() => _adding = false);
            return;
          }
        }

        // `svc.freeSpaceBytes()` above is an await and the `mounted` check
        // that follows it lives INSIDE the not-enough-space branch, so the
        // common path — enough space, or a platform that would not say —
        // reaches here having crossed an async gap unguarded. Everything
        // below touches `context` to raise the progress sheet.
        //
        // A bare `return`, not `setState(() => _adding = false)`: if the
        // element is gone the State goes with it, and setState would throw.
        if (!mounted) return;

        var ok = 0;
        var failed = 0;
        var cancelled = false;
        // Resolved BEFORE the loop on purpose. Reading them per-file meant
        // touching `ref` after an await, and if the user left mid-import the
        // read threw — caught by the inner best-effort catch, so the failure
        // was silent and its consequence was a PRIVACY one: the video stayed
        // in public history and resume state after being locked away.
        // Holding the objects instead makes the cleanup independent of
        // whether this widget is still alive.
        final history = ref.read(historyProvider.notifier);
        final resume = ref.read(resumeStorageProvider);
        final progress = VaultProgressController(
          total: picked.length,
          title: AppStrings.of(context).lockingFiles,
        );
        // NOT awaited — showDialog only completes when the sheet closes, and
        // the loop below is what closes it.
        unawaited(showVaultProgressSheet(context, progress));
        try {
          for (var i = 0; i < picked.length; i++) {
            if (progress.cancelled) {
              cancelled = true;
              break;
            }
            final f = picked[i];
            progress.beginItem(i, f.name);
            try {
              await svc.importToVault(
                videoUri: f.path,
                videoTitle: f.name,
                folderId: widget.targetFolderId,
                onProgress: progress.onBytes,
                isCancelled: () => progress.cancelled,
              );
              ok++;
              // Public-trace cleanup only makes sense for videos the
              // library may know about.
              if (_kVideoExts.contains(p.extension(f.path).toLowerCase())) {
                try {
                  await history.deleteEntry(f.path);
                  await resume.clearPosition(f.path);
                  final last = await resume.getLastPlaying();
                  if (last?.uri == f.path) await resume.clearLastPlaying();
                } catch (e) {
                  if (kDebugMode) {
                    debugPrint('add_files_picker.best-effort: $e');
                  }
                }
              }
            } on VaultCancelled {
              // Distinct from a failure: the partial copy has already been
              // removed by the service, the ORIGINAL is untouched, and
              // everything imported before this point stays in the vault.
              // Reporting it as a failure would push a user toward deleting
              // an original they still need.
              cancelled = true;
              break;
            } catch (e) {
              // A failed import (disk full, permission, bad copy) MUST be
              // surfaced — otherwise the user thinks the file is safely
              // hidden and might delete their only copy.
              failed++;
              if (kDebugMode) debugPrint('add_files_picker.vault: $e');
            }
          }
        } finally {
          progress.finish();
          if (mounted) Navigator.of(context, rootNavigator: true).pop();
        }
        if (!mounted) return;
        ref.invalidate(foldersProvider);
        if (mounted) {
          final s = AppStrings.of(context);
          final msg = cancelled
              ? s.importCancelled
              : (failed > 0 ? s.someFilesFailed(failed) : s.filesAddedOk(ok));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(msg),
              duration: const Duration(seconds: 3)));
        }
      }
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  // ── build ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        elevation: 0,
        leading: IconButton(
          icon: Icon(_searching ? Icons.arrow_back : Icons.close,
              color: Colors.white),
          tooltip: AppStrings.of(context).close,
          onPressed: () {
            // Back out of search first. Closing the whole picker because the
            // user wanted to clear a query would throw away a selection they
            // may have spent a minute building.
            if (_searching) {
              setState(() {
                _searching = false;
                _query = '';
              });
              return;
            }
            Navigator.of(context).pop(false);
          },
        ),
        titleSpacing: 0,
        title: _searching
            ? TextField(
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                cursorColor: AppColors.accentBlue,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  hintText: AppStrings.of(context).search,
                  hintStyle: const TextStyle(
                      color: AppColors.darkOnSurfaceMuted, fontSize: 16),
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : Text(widget.title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
        actions: [
          if (!_searching)
            IconButton(
              icon: const Icon(Icons.search, color: Colors.white),
              tooltip: AppStrings.of(context).search,
              onPressed: () => setState(() => _searching = true),
            ),
          // Only where there is a file list to act on. On a folder listing the
          // button would either do nothing or mean something dangerous.
          if (_hasFileList)
            IconButton(
              icon: Icon(
                _allVisiblePicked ? Icons.deselect : Icons.done_all,
                color: _allVisiblePicked ? AppColors.accentBlue : Colors.white,
              ),
              tooltip: _allVisiblePicked
                  ? AppStrings.of(context).selectionDeselectAll
                  : AppStrings.of(context).selectionSelectAll,
              onPressed: _toggleSelectAllVisible,
            ),
          // v0.94: reveal hidden folders (dot-folders + Android/data caches).
          // Only meaningful in the Files browser.
          if (_cat == _Cat.files)
            IconButton(
              icon: Icon(
                _showHidden
                    ? Icons.visibility_off
                    : Icons.visibility_off_outlined,
                color: _showHidden ? AppColors.warning : Colors.white,
              ),
              tooltip: _showHidden
                  ? AppStrings.of(context).pickerHideHidden
                  : AppStrings.of(context).pickerShowHidden,
              onPressed: _toggleShowHidden,
            ),
          // Apps have no meaningful sort/layout; hide the control there.
          if (_cat != _Cat.apps)
            IconButton(
              icon: const Icon(Icons.sort, color: Colors.white),
              tooltip: AppStrings.of(context).sortBy,
              onPressed: _openSortDialog,
            ),
        ],
      ),
      body: Column(
        children: [
          _catBar(),
          _breadcrumb(),
          Expanded(child: _body()),
        ],
      ),
      bottomNavigationBar: _picked.isNotEmpty ? _addNowBar() : null,
    );
  }

  Future<void> _toggleShowHidden() async {
    // Turning OFF is always fine.
    if (_showHidden) {
      setState(() => _showHidden = false);
      return;
    }
    // Turning ON: dot-folders show immediately from the filesystem. The
    // Android/data + Android/obb caches, though, are only readable through
    // iADB — so if the user isn't connected, offer to open the ADB screen
    // (where they connect once), then come back with hidden on.
    setState(() => _showHidden = true);
    final connected = await AdbService.instance.iadbConnected();
    if (!mounted || connected) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connect to see app-data folders'),
        content: const Text(
          'Hidden dot-folders are now shown. To also browse locked '
          'Android/data and Android/obb caches (Telegram, etc.), Innocent '
          'needs to connect through ADB. Open the ADB screen now?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Open ADB'),
          ),
        ],
      ),
    );
    if (go == true && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AdbConnectScreen()),
      );
      // On return, drop the cached listing so any newly-reachable content
      // shows without the user toggling again.
      if (mounted) {
        _invalidateListing();
        setState(() {});
      }
    }
  }

  Future<void> _openSortDialog() async {
    // Grid layout only helps the thumbnail-bearing views.
    final allowGrid = (_cat == _Cat.images) ||
        (_cat == _Cat.videos && _vFolder != null) ||
        (_cat == _Cat.images && _mFolder != null);
    final result = await PickerSortDialog.show(context, _view,
        allowGrid: allowGrid);
    if (result != null && mounted) {
      setState(() => _view = result);
    }
  }

  /// Apply the current sort to any PickedFile list. Folder lists keep their
  /// A→Z ordering (name is the only sensible key for buckets).
  /// Whatever the file list last rendered.
  ///
  /// Recorded here because [_sortFiles] is the single funnel every file list
  /// passes through, so "select all" and the counter always agree with what is
  /// actually on screen — including the search filter. Reading it from the app
  /// bar is safe: the body is built before the user can reach the button.
  List<PickedFile> _rendered = const <PickedFile>[];

  /// Live search text, or empty.
  String _query = '';
  bool _searching = false;

  List<PickedFile> _sortFiles(List<PickedFile> items) {
    // SEARCH FIRST, then sort.
    //
    // A picker that browses the whole device with no way to type a name is a
    // scrolling exercise: the Files category alone can hold thousands of
    // entries per folder. Matching is case-insensitive and unanchored, because
    // people remember a word from the middle of a filename far more often than
    // its first letters.
    final q = _query.trim().toLowerCase();
    final source =
        q.isEmpty ? items : items.where((f) => f.name.toLowerCase().contains(q));
    final sorted = [...source];
    int cmp(PickedFile a, PickedFile b) {
      switch (_view.sort) {
        case PickerSort.name:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case PickerSort.size:
          return a.sizeBytes.compareTo(b.sizeBytes);
        case PickerSort.date:
          // Older-first as the ascending base; desc flips to newest-first.
          final byDate = a.dateMs.compareTo(b.dateMs);
          return byDate != 0
              ? byDate
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    }

    sorted.sort(cmp);
    final result =
        _view.dir == PickerDir.desc ? sorted.reversed.toList() : sorted;
    _rendered = result;
    return result;
  }

  /// True when the current view is a FILE list rather than a folder list.
  ///
  /// `_rendered` is only written by [_sortFiles], which only file lists call,
  /// so a non-empty list means files are on screen.
  bool get _hasFileList => _rendered.isNotEmpty;

  bool get _allVisiblePicked =>
      _rendered.isNotEmpty &&
      _rendered.every((f) => _picked.containsKey(f.path));

  /// Tick or clear every file currently listed.
  ///
  /// Scoped to the CURRENT listing, never the whole device: a picker that can
  /// select several thousand files across every folder with one tap is a way
  /// to move somebody's entire storage into a vault by accident. It also
  /// respects the search filter, so "find *.mp4, select all" behaves the way
  /// it reads.
  void _toggleSelectAllVisible() {
    final visible = _rendered;
    if (visible.isEmpty) return;
    final allOn = visible.every((f) => _picked.containsKey(f.path));
    HapticFeedback.selectionClick();
    setState(() {
      for (final f in visible) {
        if (allOn) {
          _picked.remove(f.path);
          _pickedCat.remove(f.path);
        } else {
          _picked[f.path] = f;
          _pickedCat[f.path] = _cat;
        }
      }
    });
  }

  Widget _body() {
    switch (_cat) {
      case _Cat.videos:
        return _vFolder == null ? _videoFolderList() : _videoFileList();
      case _Cat.images:
        if (_adbMediaFiles != null) return _adbMediaFileList(showThumb: false);
        return _mFolder == null
            ? _mediaFolderList(
                ref.watch(pickerImageFoldersProvider), PickerAssetType.image)
            : _mediaFileList(showThumb: true);
      case _Cat.audio:
        if (_adbMediaFiles != null) return _adbMediaFileList(showThumb: false);
        return _mFolder == null
            ? _mediaFolderList(
                ref.watch(pickerAudioFoldersProvider), PickerAssetType.audio)
            : _mediaFileList(showThumb: false);
      case _Cat.files:
        return _fileBrowser();
      case _Cat.apps:
        return _appList();
    }
  }

  // ── category strip ────────────────────────────────────────────────
  Widget _catBar() {
    final s = AppStrings.of(context);
    final items = <(_Cat, IconData, String)>[
      (_Cat.videos, Icons.movie_outlined, s.catVideos),
      (_Cat.images, Icons.image_outlined, s.catImages),
      (_Cat.audio, Icons.music_note_outlined, s.catAudio),
      (_Cat.files, Icons.folder_open_outlined, s.catFiles),
      (_Cat.apps, Icons.android, s.catApps),
    ];
    // Height follows the text scale instead of fighting it. At the largest
    // accessibility sizes a fixed 46px row clipped the chip contents; this
    // grows with the label and stops at a sane ceiling.
    final scale = MediaQuery.textScalerOf(context).scale(13.5) / 13.5;
    final barHeight = (52.0 * scale.clamp(1.0, 1.35));
    return Container(
      height: barHeight,
      decoration: const BoxDecoration(
        color: AppColors.darkBackground,
        // A hairline under the strip so it reads as a fixed control rather
        // than floating over the content that scrolls beneath it.
        border: Border(
          bottom: BorderSide(color: AppColors.darkDivider, width: 0.6),
        ),
      ),
      child: ShaderMask(
        // Fades both edges so a clipped chip looks like "there is more this
        // way" instead of a hard crop. The stops are asymmetric-safe: with
        // the list scrolled to either end the fade simply covers empty
        // padding, so it never hides a chip the user can't reach.
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Colors.transparent,
            Colors.black,
            Colors.black,
            Colors.transparent,
          ],
          stops: [0.0, 0.045, 0.955, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: ListView.separated(
          controller: _catScroll,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final (cat, icon, label) = items[i];
            return _catChip(cat, icon, label);
          },
        ),
      ),
    );
  }

  Widget _catChip(_Cat cat, IconData icon, String label) {
    final active = _cat == cat;
    final count = _pickedIn(cat);
    return GestureDetector(
      key: _catKeys[cat],
      behavior: HitTestBehavior.opaque,
      onTap: () => _switchCat(cat),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.accentBlue : AppColors.white06,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? AppColors.accentBlue : AppColors.white08,
          ),
          // A soft lift under the selected chip. Subtle enough to read as
          // depth rather than as a second colour.
          boxShadow: active
              ? [
                  BoxShadow(
                    color: AppColors.accentBlue.withValues(alpha: 0.30),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: active ? 1.06 : 1.0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: Icon(icon,
                  size: 16,
                  color: active ? Colors.white : AppColors.white55),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? Colors.white : AppColors.white70,
                fontSize: 13.5,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            // Count of files already picked from this category. Without it
            // it is easy to tick four videos, move to Images, and lose track
            // of what the Add button is about to move.
            if (count > 0) ...[
              const SizedBox(width: 7),
              Container(
                constraints: const BoxConstraints(minWidth: 18),
                height: 18,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? AppColors.white30 : AppColors.accentBlue,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── breadcrumb ────────────────────────────────────────────────────
  Widget _breadcrumb() {
    final s = AppStrings.of(context);
    String? current;
    switch (_cat) {
      case _Cat.videos:
        current = _vFolder?.name;
        break;
      case _Cat.images:
      case _Cat.audio:
        current = _mFolder?.name;
        break;
      case _Cat.files:
        current = _dirStack.isEmpty ? null : p.basename(_dirStack.last.path);
        break;
      case _Cat.apps:
        current = null;
        break;
    }
    return Container(
      width: double.infinity,
      color: AppColors.specAddBarBg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          InkWell(
            onTap: current != null ? _popLevel : null,
            child: Text(s.storageRoot,
                style: const TextStyle(
                    color: AppColors.white70, fontSize: 14)),
          ),
          if (_cat == _Cat.files && _dirStack.length > 1) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child:
                  Icon(Icons.chevron_right, color: AppColors.white40, size: 18),
            ),
            const Text('…',
                style: TextStyle(color: AppColors.white40, fontSize: 14)),
          ],
          if (current != null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child:
                  Icon(Icons.chevron_right, color: AppColors.white40, size: 18),
            ),
            Flexible(
              child: Text(
                current,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.specAddBreadcrumb,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── VIDEOS (library providers, original UX kept) ─────────────────
  Widget _videoFolderList() {
    final foldersAsync = ref.watch(filteredFoldersProvider);
    return foldersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _centerMsg(AppStrings.of(context).couldNotLoadFolders),
      data: (folders) {
        if (folders.isEmpty) {
          return _centerMsg(AppStrings.of(context).noFolders);
        }
        return ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: folders.length,
          itemBuilder: (_, i) => _videoFolderTile(folders[i]),
        );
      },
    );
  }

  Widget _videoFolderTile(Folder f) {
    return _folderRow(
      name: f.name,
      subtitle: '${f.videoCount} videos',
      thumb: (f.coverThumbnailPath?.isNotEmpty ?? false)
          ? Image.file(File(f.coverThumbnailPath!),
              fit: BoxFit.cover,
              width: _kFolderThumb,
              height: _kFolderThumb,
              errorBuilder: (_, __, ___) => const SizedBox.shrink())
          : null,
      onTap: () => setState(() => _vFolder = f),
    );
  }

  Widget _videoFileList() {
    final folder = _vFolder;
    if (folder == null) return _videoFolderList();
    final filesAsync = ref.watch(filteredVideosProvider(folder.path));
    return filesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => _centerMsg(AppStrings.of(context).couldNotLoadFiles),
      data: (videos) {
        if (videos.isEmpty) {
          return _centerMsg(AppStrings.of(context).noVideosInFolder);
        }
        final items = <PickedFile>[];
        final thumbs = <String, String?>{};
        for (final v in videos) {
          final path = v.uri.startsWith('file://')
              ? Uri.parse(v.uri).toFilePath()
              : v.uri;
          items.add(PickedFile(
            path: path,
            name: v.title,
            sizeBytes: v.sizeBytes,
            dateMs: v.dateAdded?.millisecondsSinceEpoch ?? 0,
          ));
          thumbs[path] = v.thumbnailPath;
        }
        return _selectableList(items, videoThumbs: thumbs);
      },
    );
  }

  // ── IMAGES / AUDIO ────────────────────────────────────────────────
  Widget _mediaFolderList(
      AsyncValue<List<PickerMediaFolder>> async, PickerAssetType type) {
    final isAudio = type == PickerAssetType.audio;
    // The provider caches app-wide, so after the first resolve this is
    // synchronous data on every reopen — no spinner.
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) =>
          _centerMsg(AppStrings.of(context).noItemsHere),
      data: (folders) {
        if (folders.isEmpty && !_adbMediaConnected) {
          // Distinguish "no permission" from "genuinely empty" so the user
          // gets an actionable panel instead of a dead end.
          if (_mediaPermission == false) return _permissionPanel();
          return _centerMsg(AppStrings.of(context).noItemsHere);
        }
        return ListView.builder(
          padding: EdgeInsets.zero,
          // +1 row for the "Android/data" bucket when iADB is connected.
          itemCount: folders.length + (_adbMediaConnected ? 1 : 0),
          itemBuilder: (_, i) {
            if (_adbMediaConnected && i == 0) {
              // Special bucket: app-data media of this type, read over ADB.
              return _folderRow(
                name: 'Android/data',
                subtitle: 'App-data ${isAudio ? 'audio' : 'images'} (ADB)',
                thumb: const Icon(Icons.folder_special_outlined,
                    color: AppColors.accentBlue),
                onTap: () {
                  setState(() {
                    _loadToken++;
                    _mFolder = null;
                    // Reuse the cached scan for this type if we already ran it
                    // this session; only the first entry pays the ADB `find`.
                    _adbMediaFiles =
                        _adbMediaCache[type] ??= _loadAdbMedia(type);
                  });
                },
              );
            }
            final f = folders[i - (_adbMediaConnected ? 1 : 0)];
            // Covers resolve lazily so the list paints instantly; images
            // show a MediaStore thumbnail, audio shows a note glyph.
            return _folderRow(
              name: f.name,
              subtitle: AppStrings.of(context).itemsCount(f.count),
              thumb: isAudio
                  ? const Icon(Icons.library_music_outlined,
                      color: AppColors.white40)
                  : _MediaFolderCover(folder: f),
              onTap: () {
                setState(() {
                  _loadToken++;
                  _mFolder = f;
                  _adbMediaFiles = null;
                });
              },
            );
          },
        );
      },
    );
  }

  /// Scan Android/data for images/audio of [type] over ADB and map to
  /// PickedFiles carrying adb:// paths (pulled to a local copy on commit).
  Future<List<PickedFile>> _loadAdbMedia(PickerAssetType type) async {
    final exts = (type == PickerAssetType.audio ? _kAudioExts : _kImageExts)
        .map((e) => e.replaceFirst('.', ''))
        .toList();
    final found = await AdbService.instance.scanAndroidDataByExt(exts);
    return [
      for (final e in found)
        PickedFile(
          path: 'adb://${e.path}',
          name: e.name,
          sizeBytes: e.sizeBytes,
          dateMs: 0,
        ),
    ];
  }

  /// File list for the Android/data media bucket (Images/Audio over ADB).
  /// Thumbnails aren't shown — the files are remote adb:// paths, so an icon
  /// stands in until they're pulled on commit.
  Widget _adbMediaFileList({required bool showThumb}) {
    return FutureBuilder<List<PickedFile>>(
      future: _adbMediaFiles,
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snap.data ?? const <PickedFile>[];
        if (items.isEmpty) {
          return _centerMsg(AppStrings.of(context).noItemsHere);
        }
        return _selectableList(_sortFiles(items), imageThumbs: false);
      },
    );
  }

  Widget _mediaFileList({required bool showThumb}) {
    final folder = _mFolder;
    if (folder == null) return const SizedBox.shrink();
    // Read through the cached family provider so reopening a folder the user
    // already viewed this session is INSTANT — the previous version rebuilt a
    // fresh Future on every tap, which re-queried MediaStore and showed the
    // spinner again each time. Riverpod caches per (bucketId, type) for the
    // whole session, and now the pages already scrolled through are kept too.
    final arg = (bucketId: folder.id, type: folder.type);
    final page = ref.watch(pickerMediaItemsProvider(arg));

    // Only the FIRST page blocks the screen. Later pages arrive under a
    // footer spinner while the user keeps reading what is already there.
    if (page.initialLoad) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = [
      for (final it in page.items)
        PickedFile(
          path: it.path,
          name: it.name,
          sizeBytes: it.sizeBytes,
          dateMs: it.createdAt?.millisecondsSinceEpoch ?? 0,
        ),
    ];
    if (items.isEmpty) {
      return _centerMsg(AppStrings.of(context).noItemsHere);
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // Fetch the next page BEFORE the user reaches the bottom, so the
        // list keeps moving instead of stalling at the last row. 600px of
        // lead time is roughly a screen and a half at these row heights.
        if (!page.hasMore || page.loading) return false;
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 600) {
          // ignore: discarded_futures
          ref.read(pickerMediaItemsProvider(arg).notifier).loadMore();
        }
        return false;
      },
      child: _selectableList(
        items,
        imageThumbs: showThumb,
        footer: page.loading
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(AppStrings.of(context).loadingMore,
                        style: const TextStyle(
                            color: AppColors.white40, fontSize: 12)),
                  ],
                ),
              )
            : null,
      ),
    );
  }

  // ── FILES (real directory browser) ────────────────────────────────
  Widget _fileBrowser() {
    // Android 11+ blocks raw dart:io File listing without All-files-access:
    // directories still enumerate but regular files DON'T, so the browser
    // would show folder names and (via MediaStore) a few videos while
    // hiding everything else — exactly the reported bug. So we must KNOW
    // the permission state before rendering:
    //   • null  → still checking → spinner (never the half-empty list)
    //   • false → show the grant panel
    //   • true  → render the browser
    if (_fullStorage == null) {
      // Kick the check off once; rebuild when it returns.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _fullStorage == null) _refreshFullStorage();
      });
      return const Center(child: CircularProgressIndicator());
    }
    if (_fullStorage == false) {
      return _storageAccessPanel();
    }
    if (_dirStack.isEmpty) {
      return ref.watch(pickerStorageRootsProvider).when(
        loading: () =>
            const Center(child: CircularProgressIndicator()),
        error: (_, __) =>
            _centerMsg(AppStrings.of(context).noItemsHere),
        data: (roots) {
          if (roots.length == 1) {
            // Single volume → jump straight in.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _dirStack.isEmpty && _cat == _Cat.files) {
                setState(() => _dirStack.add(roots.first));
              }
            });
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final r in roots)
                _folderRow(
                  name: p.basename(r.path) == '0'
                      ? 'Internal storage'
                      : p.basename(r.path),
                  subtitle: r.path,
                  thumb: const Icon(Icons.sd_storage_outlined,
                      color: AppColors.white40),
                  onTap: () => setState(() => _dirStack.add(r)),
                ),
            ],
          );
        },
      );
    }
    final dir = _dirStack.last;
    return FutureBuilder<List<_DirEntry>>(
      // The future is MEMOISED (see _dirListing). Flutter rebuilds this widget
      // on every setState — ticking a file, opening a menu, a thumbnail
      // arriving — and creating the future here would restart the whole
      // directory read each time (the documented FutureBuilder pitfall). That
      // is what made big folders crawl and what let a tap during a load wedge
      // the screen.
      future: _dirListing(dir),
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _centerMsg(AppStrings.of(context).noItemsHere);
        }
        final entries = snap.data ?? const <_DirEntry>[];
        if (entries.isEmpty) {
          return _centerMsg(AppStrings.of(context).noFilesInFolder);
        }
        return ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: entries.length,
          itemBuilder: (_, i) {
            // Every value used here was computed once, off the UI thread, in
            // _listDir — no disk I/O happens while scrolling.
            final e = entries[i];
            if (e.isDir) {
              return _folderRow(
                name: e.name,
                subtitle: '',
                dense: true,
                thumb: const Icon(Icons.folder, color: AppColors.white40),
                onTap: () => _openDir(e.path),
              );
            }
            final item = PickedFile(
              // ADB-backed files carry an adb://<devicePath> uri so the commit
              // (vault / transfer) pulls a local copy; on-device files keep
              // their real filesystem path.
              path: e.adbSrcPath != null ? 'adb://${e.adbSrcPath}' : e.path,
              name: e.name,
              sizeBytes: e.sizeBytes,
              dateMs: e.dateMs,
            );
            return _fileRow(item,
                leading: Icon(_iconForExt(p.extension(e.name)),
                    color: AppColors.white55, size: 26));
          },
        );
      },
    );
  }

  /// Memoised directory listing: the future is created ONCE per
  /// (directory, sort key, sort direction, show-hidden) combination and reused
  /// across rebuilds. Flutter's FutureBuilder contract requires the future to
  /// be obtained outside build(); without this, every tap restarted the read.
  Future<List<_DirEntry>> _dirListing(Directory dir) {
    final key = '${dir.path}|${_view.sort}|${_view.dir}|$_showHidden';
    // Fast path: this exact (dir, sort, hidden) listing is already cached — the
    // common case when navigating back up a tree.
    final hit = _listCache[key];
    if (hit != null) {
      _listKey = key;
      _listFuture = hit;
      return hit;
    }
    _listKey = key;
    final f = _listDir(dir);
    _listFuture = f;
    // Bound the cache so a very deep browse can't grow it without limit; drop
    // the oldest entry when over budget (insertion order is preserved by Map).
    if (_listCache.length >= 24) {
      _listCache.remove(_listCache.keys.first);
    }
    _listCache[key] = f;
    return f;
  }

  /// Forget the cached listing so the next build re-reads the directory.
  void _invalidateListing() {
    _listKey = '';
    _listFuture = null;
    _listCache.clear();
  }

  /// Navigate into a folder.
  void _openDir(String path) {
    if (!mounted) return;
    setState(() {
      _dirStack.add(Directory(path));
      // Entering a folder shows a DIFFERENT list. Until it renders, the old
      // one is still in `_rendered`, so "select all" would tick files from the
      // folder just left — invisible on screen and impossible to notice before
      // committing them to the vault.
      _rendered = const <PickedFile>[];
    });
  }

  /// True for paths inside Android/data or Android/obb (any volume), whose
  /// contents can only be read over ADB.
  bool _isUnderAndroidData(String path) {
    return path.contains('/Android/data') || path.contains('/Android/obb');
  }

  /// Sort a mixed folder/file list the way the Files browser expects: folders
  /// first (always by name), files by the picker's chosen key + direction.
  /// Used for ADB listings (dart:io listings sort inline in [_listDir]).
  void _applyEntrySort(List<_DirEntry> entries) {
    int byName(_DirEntry a, _DirEntry b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    final dirs = entries.where((e) => e.isDir).toList()..sort(byName);
    final files = entries.where((e) => !e.isDir).toList();
    int fileCmp(_DirEntry a, _DirEntry b) {
      switch (_view.sort) {
        case PickerSort.name:
          return byName(a, b);
        case PickerSort.size:
          return a.sizeBytes.compareTo(b.sizeBytes);
        case PickerSort.date:
          return a.dateMs.compareTo(b.dateMs);
      }
    }

    files.sort(fileCmp);
    if (_view.dir == PickerDir.desc) {
      final r = files.reversed.toList();
      files
        ..clear()
        ..addAll(r);
    }
    entries
      ..clear()
      ..addAll(dirs)
      ..addAll(files);
  }

  Future<List<_DirEntry>> _listDir(Directory dir) async {
    // Android/data and Android/obb aren't readable via dart:io — list them over
    // ADB instead (real file-manager access to every app's cache), so the Files
    // browser can browse and pick ANY file type there, not just videos. Only
    // attempt this when connected; otherwise fall through to the (empty) dart:io
    // read and the browser shows its connect hint.
    if (_isUnderAndroidData(dir.path)) {
      final connected = await AdbRequiredDialog.isConnected();
      if (connected) {
        final adb = await AdbService.instance.listAdbDir(dir.path);
        final out = [
          for (final e in adb)
            _DirEntry(
              path: e.path,
              name: e.name,
              isDir: e.isDir,
              sizeBytes: e.sizeBytes,
              dateMs: 0,
              adbSrcPath: e.path,
            ),
        ];
        // listAdbDir already sorts folders-first by name; honour the picker's
        // sort for files only when the user picked size/date (name is default).
        if (_view.sort != PickerSort.name || _view.dir != PickerDir.asc) {
          _applyEntrySort(out);
        }
        return out;
      }
      // Not connected → empty; the browser's Android/data hint covers this.
      return const [];
    }
    final dirs = <_DirEntry>[];
    final rawFiles = <File>[];
    try {
      await for (final e in dir.list(followLinks: false)) {
        final name = p.basename(e.path);
        if (!_showHidden && name.startsWith('.')) continue;
        if (e is Directory) {
          dirs.add(_DirEntry(
            path: e.path,
            name: name,
            isDir: true,
            sizeBytes: 0,
            dateMs: 0,
          ));
        } else if (e is File) {
          rawFiles.add(e);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('add_files_picker.dir: $e');
    }
    // stat() every file ONCE, asynchronously and in parallel batches, so the
    // sort and the row builder never touch the disk. The old code called
    // statSync() inside the sort comparator AND again per row, which is what
    // froze the UI on folders with many files.
    final files = <_DirEntry>[];
    const batch = 48;
    for (var i = 0; i < rawFiles.length; i += batch) {
      final slice = rawFiles.skip(i).take(batch).toList();
      final stats = await Future.wait(
        slice.map((f) async {
          try {
            final st = await f.stat();
            return _DirEntry(
              path: f.path,
              name: p.basename(f.path),
              isDir: false,
              sizeBytes: st.size,
              dateMs: st.modified.millisecondsSinceEpoch,
            );
          } catch (_) {
            // Unreadable entry — still list it, just without metadata.
            return _DirEntry(
              path: f.path,
              name: p.basename(f.path),
              isDir: false,
              sizeBytes: 0,
              dateMs: 0,
            );
          }
        }),
      );
      files.addAll(stats);
    }
    int byName(_DirEntry a, _DirEntry b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    // Folders always sort by name and stay grouped at the top; files honour
    // the picker's chosen sort key + direction. Every comparison reads the
    // metadata fetched above — no I/O during the sort.
    dirs.sort(byName);
    int fileCmp(_DirEntry a, _DirEntry b) {
      switch (_view.sort) {
        case PickerSort.name:
          return byName(a, b);
        case PickerSort.size:
          return a.sizeBytes.compareTo(b.sizeBytes);
        case PickerSort.date:
          return a.dateMs.compareTo(b.dateMs);
      }
    }

    files.sort(fileCmp);
    if (_view.dir == PickerDir.desc) {
      final r = files.reversed.toList();
      files
        ..clear()
        ..addAll(r);
    }
    return [...dirs, ...files];
  }

  // ── APPS ──────────────────────────────────────────────────────────
  Widget _appList() {
    final s = AppStrings.of(context);
    // Cached app-wide: the (slow) PackageManager scan runs once, then every
    // reopen is instant.
    return ref.watch(pickerAppsProvider).when(
      loading: () => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(s.loadingApps,
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 13)),
          ],
        ),
      ),
      error: (_, __) => _centerMsg(s.appsUnavailable),
      data: (apps) {
        if (apps.isEmpty) return _centerMsg(s.noItemsHere);
        return ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: apps.length,
          itemBuilder: (_, i) {
            final a = apps[i];
            final item = PickedFile(
              path: a.apkPath,
              name: '${a.name}.apk',
              sizeBytes: a.sizeBytes,
            );
            return _fileRow(
              item,
              leading: a.icon != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(a.icon!,
                          width: 40, height: 40, fit: BoxFit.cover),
                    )
                  : const Icon(Icons.android,
                      color: AppColors.white55, size: 30),
              subtitle: a.packageName,
            );
          },
        );
      },
    );
  }

  // ── shared row builders ───────────────────────────────────────────
  /// Empty / error state.
  ///
  /// Was a single line of grey text floating in the middle of a black
  /// screen, which is indistinguishable from a view that failed to render.
  /// The icon does the real work: it tells the user at a glance whether they
  /// are looking at an empty folder or a problem, and it gives the eye
  /// somewhere to land instead of a void.
  ///
  /// Signature unchanged so all 13 call sites keep working; the icon is
  /// inferred from whether the message reads as an error, with an override
  /// for callers that know better.
  Widget _centerMsg(String msg, {IconData? icon}) {
    final s = AppStrings.of(context);
    final isError = msg == s.couldNotLoadFolders ||
        msg == s.couldNotLoadFiles ||
        msg == s.appsUnavailable;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 62,
              height: 62,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isError
                    ? AppColors.error.withValues(alpha: 0.14)
                    : AppColors.white06,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon ??
                    (isError
                        ? Icons.error_outline
                        : Icons.folder_off_outlined),
                size: 27,
                color: isError ? AppColors.error : AppColors.white30,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              msg,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.white55,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _folderRow({
    required String name,
    required String subtitle,
    required VoidCallback onTap,
    Widget? thumb,
    bool dense = false,
  }) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: dense ? 56 : _kFolderRowExtent,
        child: Row(
          children: [
            const SizedBox(width: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Container(
                width: dense ? 40 : _kFolderThumb,
                height: dense ? 40 : _kFolderThumb,
                color: AppColors.specSurface,
                alignment: Alignment.center,
                child: thumb ?? const SizedBox.shrink(),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 15)),
                  if (name.startsWith('.') || subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (name.startsWith('.')) ...[
                          const HiddenBadge(),
                          const SizedBox(width: 6),
                        ],
                        if (subtitle.isNotEmpty)
                          Flexible(
                            child: Text(subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: AppColors.white55, fontSize: 13)),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  /// Generic selectable file row (icon/thumb + name + size + checkbox).
  Widget _fileRow(PickedFile item, {Widget? leading, String? subtitle}) {
    final checked = _picked.containsKey(item.path);
    return InkWell(
      onTap: () => _toggle(item, !checked),
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            const SizedBox(width: 12),
            SizedBox(
                width: 44,
                child: Center(child: leading ?? const SizedBox.shrink())),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (_pickHidden(item.path, item.name)) ...[
                        const HiddenBadge(),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          subtitle ?? _fmtSize(item.sizeBytes),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.white55, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Checkbox(
              value: checked,
              onChanged: (v) => _toggle(item, v),
              activeColor: AppColors.accentBlue,
              side: const BorderSide(color: AppColors.white40),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  /// The videos list keeps its 16:9 thumbnails; other media reuse the
  /// same layout with a square leading.
  Widget _selectableList(List<PickedFile> items,
      {Map<String, String?>? videoThumbs,
      bool imageThumbs = false,
      Widget? footer}) {
    final sorted = _sortFiles(items);
    // A search that matches nothing must SAY so. Without this the list simply
    // renders empty, which is indistinguishable from an empty folder — the
    // user reads it as "these files are gone" rather than "your query is too
    // narrow", and the way out (clearing the query) is not suggested by
    // anything on screen.
    if (sorted.isEmpty && _query.trim().isNotEmpty) {
      return _centerMsg(AppStrings.of(context).searchNoMatches,
          icon: Icons.search_off);
    }
    // Grid only for thumbnail-bearing views AND when the user chose it.
    final hasThumbs = videoThumbs != null || imageThumbs;
    if (hasThumbs && _view.layout == PickerLayout.grid) {
      return _selectableGrid(sorted, videoThumbs: videoThumbs, footer: footer);
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      // One extra slot for the paging footer when there is one.
      itemCount: sorted.length + (footer != null ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= sorted.length) return footer!;
        final item = sorted[i];
        Widget leading;
        if (videoThumbs != null) {
          final t = videoThumbs[item.path];
          leading = ClipRRect(
            borderRadius: BorderRadius.circular(_kFileThumbR),
            child: Container(
              width: _kFileThumbW,
              height: _kFileThumbH,
              color: AppColors.specSurface,
              child: (t != null && t.isNotEmpty)
                  ? Image.file(File(t),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const SizedBox.shrink())
                  : const SizedBox.shrink(),
            ),
          );
        } else if (imageThumbs) {
          leading = ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.file(File(item.path),
                width: 46,
                height: 46,
                cacheWidth: 120,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                    Icons.image_outlined,
                    color: AppColors.white40)),
          );
        } else {
          leading = const Icon(Icons.music_note,
              color: AppColors.white55, size: 26);
        }
        final checked = _picked.containsKey(item.path);
        return InkWell(
          onTap: () => _toggle(item, !checked),
          child: SizedBox(
            height: videoThumbs != null ? 66 : 60,
            child: Row(
              children: [
                const SizedBox(width: 12),
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14)),
                      if (_pickHidden(item.path, item.name) ||
                          item.sizeBytes > 0) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (_pickHidden(item.path, item.name)) ...[
                              const HiddenBadge(),
                              const SizedBox(width: 6),
                            ],
                            if (item.sizeBytes > 0)
                              Text(_fmtSize(item.sizeBytes),
                                  style: const TextStyle(
                                      color: AppColors.white55,
                                      fontSize: 12)),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Checkbox(
                  value: checked,
                  onChanged: (v) => _toggle(item, v),
                  activeColor: AppColors.accentBlue,
                  side: const BorderSide(color: AppColors.white40),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Thumbnail grid (3-up) for images/videos. A checkmark badge marks
  /// selected cells; the whole cell is tappable.
  Widget _selectableGrid(List<PickedFile> items,
      {Map<String, String?>? videoThumbs, Widget? footer}) {
    if (footer != null) {
      // A GridView cannot host a full-width footer cell, so the paging
      // indicator sits under the grid in a column instead of inside it.
      return Column(
        children: [
          Expanded(child: _selectableGrid(items, videoThumbs: videoThumbs)),
          footer,
        ],
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final item = items[i];
        final checked = _picked.containsKey(item.path);
        final thumbPath =
            videoThumbs != null ? videoThumbs[item.path] : item.path;
        return GestureDetector(
          onTap: () => _toggle(item, !checked),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: AppColors.specSurface),
                if (thumbPath != null && thumbPath.isNotEmpty)
                  Image.file(File(thumbPath),
                      fit: BoxFit.cover,
                      cacheWidth: 240,
                      errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                          color: AppColors.white40)),
                if (videoThumbs != null)
                  const Positioned(
                    left: 4,
                    bottom: 4,
                    child: Icon(Icons.play_circle_fill,
                        color: Colors.white70, size: 20),
                  ),
                if (_pickHidden(item.path, item.name))
                  const Positioned(
                    right: 4,
                    bottom: 4,
                    child: HiddenCornerBadge(),
                  ),
                // dim + check when selected
                if (checked)
                  Container(
                      color: AppColors.accentBlue.withOpacity(0.35)),
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: checked
                          ? AppColors.accentBlue
                          : Colors.black.withOpacity(0.4),
                      border: Border.all(color: Colors.white, width: 1.4),
                    ),
                    padding: const EdgeInsets.all(1),
                    child: Icon(
                      checked ? Icons.check : Icons.circle_outlined,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _addNowBar() {
    final s = AppStrings.of(context);
    // Total bytes about to be MOVED into the vault. This is a real copy of
    // every byte, so "12 files" alone understates what the user is asking
    // for — 12 films is a very different commitment from 12 screenshots.
    // Summed only over items whose size is actually known; a total that
    // silently omits unmeasured files would be worse than no total, so the
    // line is dropped entirely rather than shown wrong.
    var totalBytes = 0;
    var known = 0;
    for (final f in _picked.values) {
      if (f.sizeBytes > 0) {
        totalBytes += f.sizeBytes;
        known++;
      }
    }
    final showSize = known == _picked.length && totalBytes > 0;
    return SafeArea(
      top: false,
      child: TweenAnimationBuilder<double>(
        // Slides up as the first file is ticked instead of the bar simply
        // existing on the next frame.
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Transform.translate(
          offset: Offset(0, (1 - t) * 56),
          child: Opacity(opacity: t, child: child),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: const BoxDecoration(
            color: AppColors.darkBackground,
            border: Border(
              top: BorderSide(color: AppColors.darkDivider, width: 0.6),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle,
                      size: 15, color: AppColors.accentBlue),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      showSize
                          ? '${s.selectedCount(_picked.length)}  ·  '
                              '${_fmtSize(totalBytes)}'
                          : s.selectedCount(_picked.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.white70, fontSize: 12.5),
                    ),
                  ),
                  // Clearing a selection used to mean un-ticking each row,
                  // possibly across several categories the user would have
                  // to remember to revisit.
                  GestureDetector(
                    onTap: _adding
                        ? null
                        : () {
                            HapticFeedback.selectionClick();
                            setState(() {
                              _picked.clear();
                              _pickedCat.clear();
                            });
                          },
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      child: Text(
                        s.clearAll,
                        style: TextStyle(
                            color: _adding
                                ? AppColors.white30
                                : AppColors.white55,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              SizedBox(
                height: 46,
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentBlue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.white15,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _adding ? null : _commit,
                  child: _adding
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.lock_outline, size: 17),
                            const SizedBox(width: 8),
                            Text('${s.addNow}  (${_picked.length})',
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static IconData _iconForExt(String ext) {
    final e = ext.toLowerCase();
    if (_kVideoExts.contains(e)) return Icons.movie_outlined;
    if (_kImageExts.contains(e)) return Icons.image_outlined;
    if (_kAudioExts.contains(e)) return Icons.music_note_outlined;
    switch (e) {
      case '.apk':
        return Icons.android;
      case '.pdf':
        return Icons.picture_as_pdf_outlined;
      case '.zip':
      case '.rar':
      case '.7z':
        return Icons.folder_zip_outlined;
      case '.txt':
      case '.doc':
      case '.docx':
        return Icons.description_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}

/// Lazily-loaded MediaStore cover for an image bucket. Resolving the
/// cover off the UI build keeps the folder list painting instantly even
/// while thumbnails are still being fetched.
class _MediaFolderCover extends StatefulWidget {
  final PickerMediaFolder folder;
  const _MediaFolderCover({required this.folder});

  @override
  State<_MediaFolderCover> createState() => _MediaFolderCoverState();
}

class _MediaFolderCoverState extends State<_MediaFolderCover> {
  String? _path;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final items = await PickerMediaSource.items(
        widget.folder.id, widget.folder.type,
        page: 0, pageSize: 1);
    if (!mounted) return;
    setState(() {
      _path = items.isNotEmpty ? items.first.path : null;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_done) {
      return const Icon(Icons.image_outlined, color: AppColors.white20);
    }
    if (_path == null) {
      return const Icon(Icons.broken_image_outlined,
          color: AppColors.white40);
    }
    return Image.file(
      File(_path!),
      fit: BoxFit.cover,
      cacheWidth: 160,
      width: _kFolderThumb,
      height: _kFolderThumb,
      errorBuilder: (_, __, ___) =>
          const Icon(Icons.image_outlined, color: AppColors.white40),
    );
  }
}
