import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/cache/library_cache.dart';
import '../../../core/services/adb/adb_service.dart';
import '../../private_folder/data/private_folder_providers.dart';
import '../../../core/services/saf/saf_service.dart';
import '../data/library_local_datasource.dart';
import '../domain/folder.dart';
import '../../user_data/user_data_providers.dart';
import '../domain/sort_options.dart';
import '../domain/video.dart';

/// Datasource provider
final libraryDataSourceProvider = Provider<LibraryLocalDataSource>((ref) {
  return LibraryLocalDataSource();
});

/// Disk cache provider — speeds up cold-start (PDF page 10 perf request)
final libraryCacheProvider = Provider<LibraryCache>((ref) {
  return LibraryCache();
});

/// Phase 13: Map of folderPath → first video URI (for folder thumbnail).
/// Computed from allVideosProvider.
final folderCoverPathsProvider = Provider<Map<String, String>>((ref) {
  final videosAsync = ref.watch(allVideosProvider);
  return videosAsync.maybeWhen(
    data: (videos) {
      final result = <String, String>{};
      for (final v in videos) {
        result.putIfAbsent(v.folderPath, () => v.uri);
      }
      return result;
    },
    orElse: () => const {},
  );
});

/// Sort/view preferences — persisted via SharedPreferences.
class LibraryPreferences {
  final SortBy sortBy;
  final SortDirection direction;
  final ViewMode viewMode;
  final LayoutMode layout;

  // Phase 29: Visible fields (matches MX Player "Fields" expandable)
  final bool showThumbnail;
  final bool showLength;
  final bool showFileExt;
  final bool showPlayedTime;
  final bool showResolution;
  final bool showFrameRate;
  final bool showPath;
  final bool showSize;
  final bool showDate;

  // Phase 29: Advanced toggles (matches MX Player "Advanced" expandable)
  final bool displayLengthOverThumb;
  final bool showHidden;
  final bool recognizeNomedia;

  const LibraryPreferences({
    this.sortBy = SortBy.date,
    this.direction = SortDirection.newestFirst,
    this.viewMode = ViewMode.folders,
    this.layout = LayoutMode.list,
    this.showThumbnail = true,
    this.showLength = true,
    this.showFileExt = false,
    this.showPlayedTime = false,
    this.showResolution = false,
    this.showFrameRate = false,
    this.showPath = false,
    this.showSize = true,
    this.showDate = true,
    this.displayLengthOverThumb = true,
    this.showHidden = false,
    this.recognizeNomedia = true,
  });

  LibraryPreferences copyWith({
    SortBy? sortBy,
    SortDirection? direction,
    ViewMode? viewMode,
    LayoutMode? layout,
    bool? showThumbnail,
    bool? showLength,
    bool? showFileExt,
    bool? showPlayedTime,
    bool? showResolution,
    bool? showFrameRate,
    bool? showPath,
    bool? showSize,
    bool? showDate,
    bool? displayLengthOverThumb,
    bool? showHidden,
    bool? recognizeNomedia,
  }) {
    return LibraryPreferences(
      sortBy: sortBy ?? this.sortBy,
      direction: direction ?? this.direction,
      viewMode: viewMode ?? this.viewMode,
      layout: layout ?? this.layout,
      showThumbnail: showThumbnail ?? this.showThumbnail,
      showLength: showLength ?? this.showLength,
      showFileExt: showFileExt ?? this.showFileExt,
      showPlayedTime: showPlayedTime ?? this.showPlayedTime,
      showResolution: showResolution ?? this.showResolution,
      showFrameRate: showFrameRate ?? this.showFrameRate,
      showPath: showPath ?? this.showPath,
      showSize: showSize ?? this.showSize,
      showDate: showDate ?? this.showDate,
      displayLengthOverThumb:
          displayLengthOverThumb ?? this.displayLengthOverThumb,
      showHidden: showHidden ?? this.showHidden,
      recognizeNomedia: recognizeNomedia ?? this.recognizeNomedia,
    );
  }
}

class LibraryPreferencesNotifier extends StateNotifier<LibraryPreferences> {
  // Key prefix lets us run two fully-independent instances off the same
  // logic: the Local tab ('lib') and the Private Folder ('pf'). Private
  // Folder must NOT share view/sort/field settings with the public Local
  // tab — changing the layout inside the vault should never alter the
  // public library (and vice-versa). Different prefixes → different
  // SharedPreferences keys → isolated state.
  final String _prefix;
  LibraryPreferencesNotifier({String prefix = 'lib'})
      : _prefix = prefix,
        super(const LibraryPreferences()) {
    _load();
  }

  String get _kSortBy => '$_prefix.sortBy';
  String get _kDir => '$_prefix.direction';
  String get _kView => '$_prefix.viewMode';
  String get _kLayout => '$_prefix.layout';
  String get _kFields => '$_prefix.fields'; // bitmask
  String get _kAdv => '$_prefix.advanced'; // bitmask

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sortByIdx = prefs.getInt(_kSortBy);
      final dirIdx = prefs.getInt(_kDir);
      final viewIdx = prefs.getInt(_kView);
      final layoutIdx = prefs.getInt(_kLayout);
      final fieldsMask = prefs.getInt(_kFields);
      final advMask = prefs.getInt(_kAdv);

      var s = state;
      if (sortByIdx != null &&
          sortByIdx >= 0 &&
          sortByIdx < SortBy.values.length) {
        s = s.copyWith(sortBy: SortBy.values[sortByIdx]);
      }
      if (dirIdx != null &&
          dirIdx >= 0 &&
          dirIdx < SortDirection.values.length) {
        s = s.copyWith(direction: SortDirection.values[dirIdx]);
      }
      if (viewIdx != null &&
          viewIdx >= 0 &&
          viewIdx < ViewMode.values.length) {
        s = s.copyWith(viewMode: ViewMode.values[viewIdx]);
      }
      if (layoutIdx != null &&
          layoutIdx >= 0 &&
          layoutIdx < LayoutMode.values.length) {
        s = s.copyWith(layout: LayoutMode.values[layoutIdx]);
      }
      if (fieldsMask != null) {
        s = s.copyWith(
          showThumbnail: (fieldsMask & 1) != 0,
          showLength: (fieldsMask & 2) != 0,
          showFileExt: (fieldsMask & 4) != 0,
          showPlayedTime: (fieldsMask & 8) != 0,
          showResolution: (fieldsMask & 16) != 0,
          showFrameRate: (fieldsMask & 32) != 0,
          showPath: (fieldsMask & 64) != 0,
          showSize: (fieldsMask & 128) != 0,
          showDate: (fieldsMask & 256) != 0,
        );
      }
      if (advMask != null) {
        s = s.copyWith(
          displayLengthOverThumb: (advMask & 1) != 0,
          showHidden: (advMask & 2) != 0,
          recognizeNomedia: (advMask & 4) != 0,
        );
      }
      state = s;
    } catch (_) {
      // Best-effort load; defaults already applied.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSortBy, state.sortBy.index);
      await prefs.setInt(_kDir, state.direction.index);
      await prefs.setInt(_kView, state.viewMode.index);
      await prefs.setInt(_kLayout, state.layout.index);
      int fieldsMask = 0;
      if (state.showThumbnail) fieldsMask |= 1;
      if (state.showLength) fieldsMask |= 2;
      if (state.showFileExt) fieldsMask |= 4;
      if (state.showPlayedTime) fieldsMask |= 8;
      if (state.showResolution) fieldsMask |= 16;
      if (state.showFrameRate) fieldsMask |= 32;
      if (state.showPath) fieldsMask |= 64;
      if (state.showSize) fieldsMask |= 128;
      if (state.showDate) fieldsMask |= 256;
      await prefs.setInt(_kFields, fieldsMask);
      int advMask = 0;
      if (state.displayLengthOverThumb) advMask |= 1;
      if (state.showHidden) advMask |= 2;
      if (state.recognizeNomedia) advMask |= 4;
      await prefs.setInt(_kAdv, advMask);
    } catch (e) { if (kDebugMode) debugPrint('library_provider.best-effort: $e'); }
  }

  void setSortBy(SortBy v) {
    state = state.copyWith(sortBy: v);
    _save();
  }

  void setDirection(SortDirection v) {
    state = state.copyWith(direction: v);
    _save();
  }

  void setViewMode(ViewMode v) {
    state = state.copyWith(viewMode: v);
    _save();
  }

  void setLayout(LayoutMode v) {
    state = state.copyWith(layout: v);
    _save();
  }

  /// Phase 29: Update Fields (Thumbnail/Length/etc) and persist.
  void setFields({
    bool? showThumbnail,
    bool? showLength,
    bool? showFileExt,
    bool? showPlayedTime,
    bool? showResolution,
    bool? showFrameRate,
    bool? showPath,
    bool? showSize,
    bool? showDate,
  }) {
    state = state.copyWith(
      showThumbnail: showThumbnail,
      showLength: showLength,
      showFileExt: showFileExt,
      showPlayedTime: showPlayedTime,
      showResolution: showResolution,
      showFrameRate: showFrameRate,
      showPath: showPath,
      showSize: showSize,
      showDate: showDate,
    );
    _save();
  }

  /// Phase 29: Update Advanced toggles and persist.
  void setAdvanced({
    bool? displayLengthOverThumb,
    bool? showHidden,
    bool? recognizeNomedia,
  }) {
    state = state.copyWith(
      displayLengthOverThumb: displayLengthOverThumb,
      showHidden: showHidden,
      recognizeNomedia: recognizeNomedia,
    );
    _save();
  }

  /// Cycle view mode: All folders → Files → Folders → All folders
  void cycleViewMode() {
    const values = ViewMode.values;
    final next = values[(state.viewMode.index + 1) % values.length];
    state = state.copyWith(viewMode: next);
    _save();
  }
}

final libraryPreferencesProvider =
    StateNotifierProvider<LibraryPreferencesNotifier, LibraryPreferences>(
  (ref) => LibraryPreferencesNotifier(prefix: 'lib'),
);

/// Independent view/sort/field preferences for the Private Folder screen.
/// Uses the SAME notifier logic but a separate 'pf' key namespace, so the
/// vault's layout is fully isolated from the public Local tab — toggling
/// List/Grid (or any field) inside the Private Folder never changes the
/// Local tab, and vice-versa.
final privateFolderPreferencesProvider =
    StateNotifierProvider<LibraryPreferencesNotifier, LibraryPreferences>(
  (ref) => LibraryPreferencesNotifier(prefix: 'pf'),
);

/// Search query state
final searchQueryProvider = StateProvider<String>((ref) => '');

/// All folders, scanned from MediaStore.
/// Cache-first: returns cached snapshot immediately, kicks off fresh fetch in background.
final foldersProvider = FutureProvider<List<Folder>>((ref) async {
  final ds = ref.watch(libraryDataSourceProvider);
  final cache = ref.watch(libraryCacheProvider);

  // Try cache first for instant load
  final cached = await cache.loadFolders();
  if (cached != null && cached.isNotEmpty) {
    // Kick off background refresh that will invalidate when done
    // ignore: discarded_futures
    () async {
      try {
        final fresh = await ds.getFolders();
        await cache.saveFolders(fresh);
        // Trigger consumer update only if data changed materially
        if (_hasFolderDiff(cached, fresh)) {
          ref.invalidateSelf();
        }
      } catch (e, st) {
        // Code-quality audit: was silent. Background refresh
        // failures are non-fatal (we keep showing the cached list)
        // but we want the trace in debug builds so a recurring
        // permission/IO problem is visible to the developer.
        if (kDebugMode) debugPrint('foldersProvider background refresh failed: $e\n$st');
      }
    }();
    return cached;
  }

  // No cache → fetch fresh, then save
  final fresh = await ds.getFolders();
  await cache.saveFolders(fresh);
  return fresh;
});

bool _hasFolderDiff(List<Folder> a, List<Folder> b) {
  if (a.length != b.length) return true;
  final aPaths = a.map((f) => f.path).toSet();
  final bPaths = b.map((f) => f.path).toSet();
  return aPaths.length != bPaths.length || !aPaths.containsAll(bPaths);
}

/// All videos across folders (flat list, for "Videos" view mode).
/// Cache-first for fast cold-start.
final allVideosProvider = FutureProvider<List<Video>>((ref) async {
  final ds = ref.watch(libraryDataSourceProvider);
  final cache = ref.watch(libraryCacheProvider);

  final cached = await cache.loadAllVideos();
  if (cached != null && cached.isNotEmpty) {
    // ignore: discarded_futures
    () async {
      try {
        final fresh = await ds.getAllVideos();
        await cache.saveAllVideos(fresh);
        if (fresh.length != cached.length) {
          ref.invalidateSelf();
        }
      } catch (e, st) {
        // Code-quality audit: was silent. See foldersProvider for
        // rationale — keep the trace in debug builds.
        if (kDebugMode) debugPrint('allVideosProvider background refresh failed: $e\n$st');
      }
    }();
    return cached;
  }

  final fresh = await ds.getAllVideos();
  await cache.saveAllVideos(fresh);
  return fresh;
});

/// Folder path → total size in bytes, derived from [allVideosProvider].
///
/// The fast folder scan deliberately skips per-folder sizes (it only reads
/// one asset per bucket), so the size chip in the folder list would never
/// appear. This provider fills it in lazily: once the full video list is
/// ready it groups by folder and sums sizes — cheap O(videos) work that
/// never blocks the folder scan itself. Returns an empty map until then.
final folderSizesProvider = Provider<Map<String, int>>((ref) {
  final videos = ref.watch(allVideosProvider).maybeWhen(
        data: (v) => v,
        orElse: () => const <Video>[],
      );
  if (videos.isEmpty) return const <String, int>{};
  final map = <String, int>{};
  for (final v in videos) {
    map[v.folderPath] = (map[v.folderPath] ?? 0) + v.sizeBytes;
  }
  return map;
});

/// Folders excluded because a `.nomedia` sits in them or above them.
///
/// MX Player's rule is inherited: one `.nomedia` at the top of a tree hides
/// everything beneath it, which is how WhatsApp and similar apps mark media
/// they don't want indexed. Checking only the file's own folder would leave
/// most of such a tree visible.
///
/// This existed as a switch in TWO screens and was read by neither, so the
/// feature did not exist at all — and the two switches stored separate values,
/// so turning one on left the other looking off.
///
/// Cost is bounded. Each distinct folder is walked upward once and every
/// directory seen on the way is memoised in the same pass, so a library of two
/// thousand videos across eighty folders performs tens of `exists()` calls
/// rather than thousands. Returns empty immediately when the setting is off.
final nomediaBlockedFoldersProvider =
    FutureProvider<Set<String>>((ref) async {
  final recognize =
      ref.watch(libraryPreferencesProvider.select((p) => p.recognizeNomedia));
  if (!recognize) return const <String>{};
  final videos = ref.watch(allVideosProvider).maybeWhen(
        data: (v) => v,
        orElse: () => const <Video>[],
      );
  if (videos.isEmpty) return const <String>{};

  final blocked = <String>{};
  final known = <String, bool>{}; // directory -> it or an ancestor is blocked

  Future<void> resolve(String dir) async {
    if (known.containsKey(dir)) return;
    // Collect the chain up to the first directory we already know about (or
    // the volume root), then resolve top-down so one pass answers all of them.
    final chain = <String>[];
    var cur = dir;
    var inherited = false;
    while (true) {
      final hit = known[cur];
      if (hit != null) {
        inherited = hit;
        break;
      }
      chain.add(cur);
      final up = p.dirname(cur);
      // dirname stops changing at the volume root; the depth cap is a guard
      // against a pathological path rather than an expected case.
      if (up == cur || chain.length > 24) break;
      cur = up;
    }
    var acc = inherited;
    for (final d in chain.reversed) {
      acc = acc || await _hasNomedia(d);
      known[d] = acc;
      if (acc) blocked.add(d);
    }
  }

  for (final folder in videos.map((v) => v.folderPath).toSet()) {
    // adb:// and content:// are not filesystem paths — probing them would
    // just throw.
    if (folder.isEmpty || folder.contains('://')) continue;
    try {
      await resolve(folder);
    } catch (e) {
      if (kDebugMode) debugPrint('nomedia probe failed for $folder: $e');
    }
  }
  return blocked;
});

Future<bool> _hasNomedia(String dir) async {
  try {
    return await File(p.join(dir, '.nomedia')).exists();
  } catch (_) {
    // Unreadable directory: treat as not blocked. Hiding media because we
    // could not read a folder would be worse than showing it.
    return false;
  }
}

/// Filesystem-walk videos, used ONLY to reveal hidden files (dot files,
/// `.nomedia` folders, `Android/media`) that MediaStore never indexes. The
/// walk is opt-in: it returns an empty list unless "Show hidden files and
/// folders" is on, so the normal MediaStore path pays nothing for it.
final filesystemVideosProvider = FutureProvider<List<Video>>((ref) async {
  final showHidden =
      ref.watch(libraryPreferencesProvider.select((p) => p.showHidden));
  if (!showHidden) return const <Video>[];
  final ds = ref.watch(libraryDataSourceProvider);
  try {
    return await ds.scanFilesystemVideos();
  } catch (e, st) {
    if (kDebugMode) debugPrint('filesystemVideosProvider failed: $e\n$st');
    return const <Video>[];
  }
});

/// Currently-persisted SAF grants (for the Settings tile subtitle/count).
final safGrantedTreesProvider = FutureProvider<List<String>>((ref) async {
  return SafService.instance.grantedTrees();
});

/// Videos found inside Android/data|obb by the ADB scan, surfaced as Video
/// objects so they appear in the Local library. They can't be read by the app
/// directly, so their uri is an "adb://<path>" marker; the player streams (or
/// copies) the file out via ADB on play (see PlayerPlayback._doOpenVideo).
/// These are shown in Local whenever a scan has found any — scanning is itself
/// the opt-in, so they do NOT depend on the "Show hidden" toggle (they carry a
/// Hidden badge instead).
final adbVideosProvider = FutureProvider<List<Video>>((ref) async {
  try {
    final lines = await AdbService.instance.savedScannedVideos();
    final out = <Video>[];
    for (final line in lines) {
      if (line.isEmpty) continue;
      final parsed = parseAdbScanLine(line);
      final path = parsed.path;
      if (path.isEmpty) continue;
      out.add(Video(
        id: 'adb:$path',
        uri: 'adb://$path',
        title: _stripName(path.split('/').last),
        folderPath: p.dirname(path),
        duration: Duration.zero,
        sizeBytes: parsed.sizeBytes,
        width: 0,
        height: 0,
        mimeType: null,
        dateAdded: null,
      ));
    }
    return out;
  } catch (e, st) {
    if (kDebugMode) debugPrint('adbVideosProvider failed: $e\n$st');
    return const <Video>[];
  }
});

/// Android/data videos as a plain list, always (decoupled from "Show hidden").
/// Folder paths currently excluded by a `.nomedia`, or empty when the setting
/// is off or the probe has not resolved yet.
Set<String> _nomediaBlocked(Ref ref) =>
    ref.watch(nomediaBlockedFoldersProvider).maybeWhen(
          data: (s) => s,
          orElse: () => const <String>{},
        );

List<Video> _adbVideos(Ref ref) => ref.watch(adbVideosProvider).maybeWhen(
      data: (v) => v,
      orElse: () => const <Video>[],
    );

/// Outcome of a library refresh, so the caller can tell the user what happened
/// (especially when the iADB connection dropped mid-refresh).
enum LibraryRefreshResult {
  /// Device media refreshed; iADB wasn't the backend or wasn't connected, so no
  /// app-data scan was attempted. Nothing to tell the user.
  deviceOnly,

  /// iADB was connected and the Android/data scan completed.
  adbScanned,

  /// iADB was supposed to be the source but the connection was down or dropped
  /// during the scan. Existing app-data videos are kept; the caller should
  /// gently prompt the user to reconnect.
  adbDisconnected,
}

/// Full library refresh used by pull-to-refresh and the ⋮ "Refresh" action.
///
/// Re-scans the device's own media (folders + videos) AND, when iADB is
/// connected, re-scans Android/data so hidden app-cache videos refresh at the
/// same time — the user shouldn't have to open the ADB screen to update them.
/// Safe to call anywhere: the ADB scan is skipped unless the iADB backend is
/// actually connected, and any failure is swallowed so a refresh never throws.
///
/// If the iADB connection drops during the scan, the previously-scanned
/// app-data videos are DELIBERATELY kept (not wiped) and the result reports
/// [LibraryRefreshResult.adbDisconnected] so the caller can prompt a reconnect.
Future<LibraryRefreshResult> refreshLibraryWithAdb(WidgetRef ref) async {
  // Kick off the device media refresh (always).
  ref.invalidate(foldersProvider);
  ref.invalidate(allVideosProvider);

  var result = LibraryRefreshResult.deviceOnly;
  // If iADB is the backend, re-scan Android/data and refresh the adb videos.
  try {
    final backend = await AdbService.instance.getBackend();
    if (backend == 'iadb') {
      // Whether the user already had app-data videos showing. Only if they did
      // is a "connection lost" nudge meaningful — otherwise they simply haven't
      // connected yet and shouldn't be nagged on every pull-to-refresh.
      final hadAdbVideos = ref.read(adbVideosProvider).maybeWhen(
            data: (v) => v.isNotEmpty,
            orElse: () => false,
          );
      final connectedBefore = await AdbService.instance.iadbConnected();
      if (connectedBefore) {
        try {
          final paths = await AdbService.instance.scanAndroidDataVideos();
          if (paths.isNotEmpty) ref.invalidate(adbVideosProvider);
          result = LibraryRefreshResult.adbScanned;
        } catch (e) {
          // The scan failed — most commonly because iADB dropped mid-scan.
          // KEEP the existing app-data videos (invalidating here would blank
          // them). Report a drop only if the user actually had videos to lose.
          if (kDebugMode) debugPrint('refreshLibraryWithAdb scan: $e');
          final stillConnected =
              await AdbService.instance.iadbConnected().catchError((_) => false);
          if (stillConnected) {
            result = LibraryRefreshResult.adbScanned;
          } else {
            result = hadAdbVideos
                ? LibraryRefreshResult.adbDisconnected
                : LibraryRefreshResult.deviceOnly;
          }
        }
      } else {
        // iADB backend selected but not connected. Only nudge if they had
        // app-data videos before (i.e. the connection was lost, not never made).
        result = hadAdbVideos
            ? LibraryRefreshResult.adbDisconnected
            : LibraryRefreshResult.deviceOnly;
      }
    }
  } catch (e) {
    if (kDebugMode) debugPrint('refreshLibraryWithAdb: $e');
  }

  // Await the device rescan so a RefreshIndicator spinner lasts until data is
  // actually back.
  try {
    await ref.read(foldersProvider.future);
  } catch (_) {}
  return result;
}

/// Auto-scans Android/data for videos the moment iADB connects, so they show
/// up in Local without the user having to open the ADB screen and tap "Scan"
/// first. The manual Scan button stays (for a deliberate re-scan); this just
/// makes the common case automatic.
///
/// Kept alive for the whole app session by a watch in the shell, so a connect
/// that happens while the user is anywhere in the app still triggers a scan.
/// It listens to the native iADB state signal, debounces to the first
/// connected transition, runs the (backend-agnostic) scan on a worker, and
/// invalidates [adbVideosProvider] so Local refreshes.
final adbAutoScanProvider = Provider<void>((ref) {
  var scanning = false;
  var lastConnected = false;

  Future<void> maybeScan() async {
    // Only the iADB backend auto-scans; the built-in backend's connection is
    // transient and the user drives it from the ADB screen.
    String backend;
    try {
      backend = await AdbService.instance.getBackend();
    } catch (_) {
      return;
    }
    if (backend != 'iadb') return;

    bool connected;
    try {
      connected = await AdbService.instance.iadbConnected();
    } catch (_) {
      connected = false;
    }
    // Fire only on the transition into "connected" (not on every signal), and
    // never re-enter while a scan is in flight.
    if (!connected) {
      lastConnected = false;
      return;
    }
    if (lastConnected || scanning) return;
    lastConnected = true;
    scanning = true;
    try {
      final paths = await AdbService.instance.scanAndroidDataVideos();
      // Refresh Local so the freshly-scanned videos appear. Only bother if the
      // provider is still alive and something was found (an empty scan on a
      // connect with no app-data videos shouldn't wipe a prior good result).
      if (paths.isNotEmpty) {
        ref.invalidate(adbVideosProvider);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('adbAutoScan failed: $e');
    } finally {
      scanning = false;
    }
  }

  final dispose =
      AdbService.instance.addIadbStateListener(() => maybeScan());
  ref.onDispose(dispose);
  // Also run once now: if iADB is already connected when this provider first
  // comes alive (e.g. app relaunched while iADB stayed connected), scan
  // without waiting for a state-change signal that won't come.
  maybeScan();
});

/// SAF-granted videos (Android/data etc.) as Video objects, opt-in like the
/// filesystem walk. Each carries its playable content:// URI plus a derived
/// filesystem-style folder path so it groups into folders naturally.
final safVideosProvider = FutureProvider<List<Video>>((ref) async {  final showHidden =
      ref.watch(libraryPreferencesProvider.select((p) => p.showHidden));
  if (!showHidden) return const <Video>[];
  try {
    final saf = await SafService.instance.listVideos();
    final out = <Video>[];
    for (final s in saf) {
      final abs = _safAbsolutePath(s.docPath, s.name);
      out.add(Video(
        id: 'saf:${s.uri}',
        uri: s.uri, // content:// — playable straight through
        title: _stripName(s.name),
        folderPath: abs.isEmpty ? '' : p.dirname(abs),
        duration: Duration.zero,
        sizeBytes: s.sizeBytes,
        width: 0,
        height: 0,
        mimeType: null,
        dateAdded: null,
      ));
    }
    return out;
  } catch (e, st) {
    if (kDebugMode) debugPrint('safVideosProvider failed: $e\n$st');
    return const <Video>[];
  }
});

/// Map a SAF document id ("primary:Android/data/com.x/files/a.mp4" or
/// "XXXX-XXXX:Movies/a.mp4") to a real filesystem-style absolute path so hidden
/// SAF entries group into the same folder structure as the filesystem walk.
String _safAbsolutePath(String docPath, String name) {
  final colon = docPath.indexOf(':');
  if (colon < 0) return docPath;
  final vol = docPath.substring(0, colon);
  final rel = docPath.substring(colon + 1);
  final root = vol == 'primary' ? '/storage/emulated/0' : '/storage/$vol';
  return rel.isEmpty ? root : '$root/$rel';
}

/// Strip a trailing file extension for display (MX-Player parity).
String _stripName(String s) {
  final dot = s.lastIndexOf('.');
  if (dot <= 0) return s;
  final ext = s.substring(dot + 1);
  if (ext.length > 5 || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(ext)) return s;
  return s.substring(0, dot);
}

/// Hidden videos as a plain list = filesystem-walk videos + SAF-granted videos
/// (empty when the toggle is off or both are still running). The two cover
/// disjoint areas — the walk handles everything except Android/data|obb on 11+,
/// SAF handles the granted trees — so a plain concat needs no cross-dedup.
/// Hidden videos as a plain list = filesystem-walk videos + SAF-granted videos
/// (empty when the toggle is off or both are still running). Android/data (adb)
/// videos are handled separately via [_adbVideos] since they show regardless of
/// the toggle. The two here cover disjoint areas — the walk handles everything
/// except Android/data|obb on 11+, SAF handles the granted trees — so a plain
/// concat needs no cross-dedup.
List<Video> _hiddenVideos(Ref ref) {
  final fs = ref.watch(filesystemVideosProvider).maybeWhen(
        data: (v) => v,
        orElse: () => const <Video>[],
      );
  final saf = ref.watch(safVideosProvider).maybeWhen(
        data: (v) => v,
        orElse: () => const <Video>[],
      );
  final out = <Video>[...fs, ...saf];
  return out;
}


/// URIs the user has sent to the Recycle Bin.
///
/// ─── THE BIN DID NOT ACTUALLY HIDE ANYTHING (found 27 Aug 2026) ──────────
///
/// `recycleBinProvider` had exactly one reader — the Recycle Bin screen. Three
/// places WROTE to it (the per-video option menu, and both multi-select bars),
/// each reporting "Moved to Recycle Bin", and the video then stayed exactly
/// where it was in every list.
///
/// That is worse than not having the feature. Someone who binned a video and
/// handed their phone over was told it was gone. The screen even offered
/// "restore", implying there was something to restore FROM.
///
/// Matching on the normalised URI rather than the raw string, because the same
/// file arrives as `content://`, `file://` or a bare path depending on which
/// scanner found it, and a bin entry written from one must still match a list
/// entry built from another.
Set<String> _recycledUris(Ref ref) {
  final entries = ref.watch(recycleBinProvider);
  if (entries.isEmpty) return const <String>{};
  return <String>{
    for (final e in entries) normalizeMediaUri(e.videoUri),
  };
}

/// Sorted + filtered flat video list (for Files view mode)
final filteredAllVideosProvider = Provider<AsyncValue<List<Video>>>((ref) {
  final videosAsync = ref.watch(allVideosProvider);
  final prefs = ref.watch(libraryPreferencesProvider);
  final query = ref.watch(searchQueryProvider).trim().toLowerCase();

  return videosAsync.whenData((videos) {
    // Android/data (adb) videos always show — scanning them is itself the
    // opt-in, so they don't depend on "Show hidden".
    final adb = _adbVideos(ref);
    var base = videos;
    if (adb.isNotEmpty) {
      final have = videos.map((v) => v.uri).toSet();
      base = [...videos, ...adb.where((v) => !have.contains(v.uri))];
    }
    // When "Show hidden files" is on, fold in the filesystem-walk videos that
    // MediaStore never returned (deduped against the list so far by path).
    if (prefs.showHidden) {
      final fs = _hiddenVideos(ref);
      if (fs.isNotEmpty) {
        final have = base.map((v) => v.uri).toSet();
        base = [...base, ...fs.where((v) => !have.contains(v.uri))];
      }
    }
    var filtered = base;
    // Phase 29: respect "Show hidden files and folders" toggle.
    // A "hidden" video here = file or any parent folder starts with '.'.
    // adb:// videos are exempt — they were explicitly scanned.
    if (!prefs.showHidden) {
      filtered = base
          .where((v) =>
              v.uri.startsWith('adb://') || !_isHidden(v.title, v.folderPath))
          .toList();
    }
    // "Recognize .nomedia". adb:// entries are exempt for the same reason as
    // above: scanning them is itself the opt-in.
    final nomedia = _nomediaBlocked(ref);
    if (nomedia.isNotEmpty) {
      filtered = filtered
          .where((v) =>
              v.uri.startsWith('adb://') || !nomedia.contains(v.folderPath))
          .toList();
    }
    // Recycle Bin. Applied LAST of the exclusions and before the search, so a
    // binned video cannot come back through a query that happens to match it.
    final recycled = _recycledUris(ref);
    if (recycled.isNotEmpty) {
      filtered = filtered
          .where((v) => !recycled.contains(normalizeMediaUri(v.uri)))
          .toList();
    }
    if (query.isNotEmpty) {
      filtered = filtered
          .where((v) => v.title.toLowerCase().contains(query))
          .toList();
    }
    return _sortVideos(
      filtered,
      prefs,
      _WatchIndex(
        ref.watch(lastWatchedProvider),
        ref.watch(watchProgressProvider),
        normalizeMediaUri,
      ),
    );
  });
});

/// Sorted + filtered folder list. Matches folder name OR any video name within the folder.
final filteredFoldersProvider = Provider<AsyncValue<List<Folder>>>((ref) {
  final foldersAsync = ref.watch(foldersProvider);
  final allVideosAsync = ref.watch(allVideosProvider);
  final prefs = ref.watch(libraryPreferencesProvider);
  final query = ref.watch(searchQueryProvider).trim().toLowerCase();

  return foldersAsync.whenData((folders) {
    // Synthesise folders for any directory the MediaStore folder list didn't
    // bucket. Android/data (adb) folders are always included (scanning is the
    // opt-in); filesystem-walk hidden folders only when "Show hidden" is on.
    final havePaths = folders.map((f) => f.path).toSet();

    List<Folder> synth(List<Video> vids) {
      final grouped = <String, List<Video>>{};
      for (final v in vids) {
        grouped.putIfAbsent(v.folderPath, () => <Video>[]).add(v);
      }
      final result = <Folder>[];
      grouped.forEach((path, vs) {
        if (havePaths.contains(path)) return;
        havePaths.add(path); // avoid dupes across the adb + fs passes
        var total = 0;
        for (final v in vs) {
          total += v.sizeBytes;
        }
        result.add(Folder(
          path: path,
          name: (path.contains('/Android/data/') ||
                  path.contains('/Android/obb/'))
              ? _adbFolderDisplayName(path)
              : p.basename(path),
          videoCount: vs.length,
          coverThumbnailPath: vs.first.uri,
          totalSizeBytes: total,
        ));
      });
      return result;
    }

    final extra = <Folder>[];
    final adb = _adbVideos(ref);
    if (adb.isNotEmpty) extra.addAll(synth(adb));
    if (prefs.showHidden) {
      final fs = _hiddenVideos(ref);
      if (fs.isNotEmpty) extra.addAll(synth(fs));
    }
    var base = extra.isEmpty ? folders : [...folders, ...extra];

    // "Recognize .nomedia" hides the folder from THIS list. Opening a folder
    // deliberately (via search, or a path the user navigates to) still shows
    // its contents — .nomedia is an indexing hint, not a lock, and MX Player
    // treats it the same way.
    final nomedia = _nomediaBlocked(ref);
    if (nomedia.isNotEmpty) {
      base = base
          .where((f) =>
              f.path.startsWith('adb://') || !nomedia.contains(f.path))
          .toList();
    }

    var filtered = base;
    // Phase 29: respect "Show hidden files and folders" toggle. adb folders
    // (from an explicit scan) are exempt.
    if (!prefs.showHidden) {
      filtered = base
          .where((f) =>
              (f.coverThumbnailPath?.startsWith('adb://') ?? false) ||
              !_isHidden(f.name, f.path))
          .toList();
    }
    if (query.isNotEmpty) {
      // Folders whose name matches OR which contain a video matching the query
      final matchingPaths = <String>{};
      // Folder name match
      for (final f in filtered) {
        if (f.name.toLowerCase().contains(query)) {
          matchingPaths.add(f.path);
        }
      }
      // Video name match → add containing folder
      final allVideos = allVideosAsync.maybeWhen(
        data: (v) => v,
        orElse: () => const [],
      );
      for (final v in allVideos) {
        if (v.title.toLowerCase().contains(query)) {
          matchingPaths.add(v.folderPath);
        }
      }
      filtered = filtered.where((f) => matchingPaths.contains(f.path)).toList();
    }
    // Recycle Bin: correct the counts, and drop a folder whose every video is
    // binned. Without this a folder reads "12 videos" and opens to show 10 —
    // and an emptied folder sits in the list forever with nothing inside it.
    final recycled = _recycledUris(ref);
    if (recycled.isNotEmpty) {
      final allVideos = allVideosAsync.maybeWhen(
        data: (v) => v,
        orElse: () => const <Video>[],
      );
      final binnedPerFolder = <String, int>{};
      final binnedBytes = <String, int>{};
      for (final v in allVideos) {
        if (!recycled.contains(normalizeMediaUri(v.uri))) continue;
        binnedPerFolder[v.folderPath] =
            (binnedPerFolder[v.folderPath] ?? 0) + 1;
        binnedBytes[v.folderPath] =
            (binnedBytes[v.folderPath] ?? 0) + v.sizeBytes;
      }
      if (binnedPerFolder.isNotEmpty) {
        final adjusted = <Folder>[];
        for (final f in filtered) {
          final gone = binnedPerFolder[f.path] ?? 0;
          if (gone == 0) {
            adjusted.add(f);
            continue;
          }
          final left = f.videoCount - gone;
          if (left <= 0) continue;
          adjusted.add(Folder(
            path: f.path,
            name: f.name,
            videoCount: left,
            coverThumbnailPath: f.coverThumbnailPath,
            newCount: f.newCount,
            totalSizeBytes:
                (f.totalSizeBytes - (binnedBytes[f.path] ?? 0)).clamp(0, f.totalSizeBytes),
          ));
        }
        filtered = adjusted;
      }
    }
    return _sortFolders(filtered, prefs);
  });
});

/// Phase 29: helper — returns true when a file/folder path looks hidden
/// (Unix-style ".name" or any ancestor folder starts with '.').
bool _isHidden(String name, String fullPath) {
  if (name.startsWith('.')) return true;
  for (final part in fullPath.split('/')) {
    if (part.isNotEmpty && part.startsWith('.')) return true;
  }
  return false;
}

/// A clearer display name for an Android/data|obb folder than a bare "cache" or
/// "files": prefix it with the owning app package so several apps' cache folders
/// are distinguishable in the Folders view. e.g.
/// /storage/emulated/0/Android/data/com.iMe.android/cache -> "com.iMe.android · cache".
String _adbFolderDisplayName(String path) {
  // Show ONLY the folder that directly contains the videos (e.g. "videos",
  // "Telegram Video"), not the long package path. The hidden origin is shown as
  // a small label under the name in the folder tile, so the name stays short
  // and clean. Fall back to the last non-empty segment if basename is empty.
  final base = p.basename(path);
  if (base.isNotEmpty) return base;
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

List<Folder> _sortFolders(List<Folder> folders, LibraryPreferences prefs) {
  final sorted = List<Folder>.from(folders);
  switch (prefs.sortBy) {
    case SortBy.title:
      sorted.sort((a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      break;
    case SortBy.size:
    case SortBy.length:
      // Folder doesn't track size/length yet — fall back to videoCount
      sorted.sort((a, b) => b.videoCount.compareTo(a.videoCount));
      break;
    case SortBy.date:
    case SortBy.playedTime:
    case SortBy.resolution:
    case SortBy.status:
    case SortBy.path:
    case SortBy.frameRate:
    case SortBy.type:
      // Folder doesn't track these — fall back to title
      sorted.sort((a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      break;
  }
  if (prefs.direction == SortDirection.oldestFirst) {
    return sorted.reversed.toList();
  }
  return sorted;
}

/// Videos in a specific folder (parameterized)
final videosInFolderProvider =
    FutureProvider.family<List<Video>, String>((ref, folderPath) async {
  final ds = ref.watch(libraryDataSourceProvider);
  final cache = ref.watch(libraryCacheProvider);

  // Android/data (adb) videos that live directly in this folder — always
  // included so tapping an Android/data folder actually shows its videos
  // (MediaStore never returns them). Decoupled from the "Show hidden" toggle.
  final adbHere =
      _adbVideos(ref).where((v) => v.folderPath == folderPath).toList();
  List<Video> withAdb(List<Video> base) {
    if (adbHere.isEmpty) return base;
    final have = base.map((v) => v.uri).toSet();
    return [...base, ...adbHere.where((v) => !have.contains(v.uri))];
  }

  // Phase 44: cache-first so tapping a previously-visited folder shows
  // its videos instantly. A fresh MediaStore scan runs in the background
  // and triggers an invalidate when something actually changed (added,
  // removed or renamed files).
  final cached = await cache.loadVideosInFolder(folderPath);
  if (cached != null && cached.isNotEmpty) {
    // ignore: discarded_futures
    () async {
      try {
        final fresh = await ds.getVideosInFolder(folderPath);
        await cache.saveVideosInFolder(folderPath, fresh);
        if (_hasVideoListDiff(cached, fresh)) {
          ref.invalidateSelf();
        }
      } catch (e) { if (kDebugMode) debugPrint('library_provider.best-effort: $e'); }
    }();
    return withAdb(cached);
  }

  // No cache → fetch fresh, then save for next visit.
  final fresh = await ds.getVideosInFolder(folderPath);
  await cache.saveVideosInFolder(folderPath, fresh);
  return withAdb(fresh);
});

bool _hasVideoListDiff(List<Video> a, List<Video> b) {
  if (a.length != b.length) return true;
  final aUris = a.map((v) => v.uri).toSet();
  final bUris = b.map((v) => v.uri).toSet();
  return aUris.length != bUris.length || !aUris.containsAll(bUris);
}

/// Sorted + filtered video list inside folder
final filteredVideosProvider =
    Provider.family<AsyncValue<List<Video>>, String>((ref, folderPath) {
  final videosAsync = ref.watch(videosInFolderProvider(folderPath));
  final prefs = ref.watch(libraryPreferencesProvider);
  final query = ref.watch(searchQueryProvider).trim().toLowerCase();

  return videosAsync.whenData((videos) {
    // Fold in hidden filesystem videos that belong to THIS folder (deduped),
    // so opening a hidden/.nomedia folder shows its contents too.
    var base = videos;
    if (prefs.showHidden) {
      final fs = _hiddenVideos(ref);
      if (fs.isNotEmpty) {
        final have = videos.map((v) => v.uri).toSet();
        base = [
          ...videos,
          ...fs.where(
              (v) => v.folderPath == folderPath && !have.contains(v.uri)),
        ];
      }
    }
    var filtered = base;
    // Recycle Bin. Applied LAST of the exclusions and before the search, so a
    // binned video cannot come back through a query that happens to match it.
    final recycled = _recycledUris(ref);
    if (recycled.isNotEmpty) {
      filtered = filtered
          .where((v) => !recycled.contains(normalizeMediaUri(v.uri)))
          .toList();
    }
    if (query.isNotEmpty) {
      filtered = filtered
          .where((v) => v.title.toLowerCase().contains(query))
          .toList();
    }
    return _sortVideos(
      filtered,
      prefs,
      _WatchIndex(
        ref.watch(lastWatchedProvider),
        ref.watch(watchProgressProvider),
        normalizeMediaUri,
      ),
    );
  });
});

/// Watch data the sort needs, gathered once per sort rather than looked up
/// per comparison — a comparator runs O(n log n) times and must stay cheap.
class _WatchIndex {
  final Map<String, DateTime> lastWatched;
  final Map<String, double> progress;
  final String Function(String) normalize;
  const _WatchIndex(this.lastWatched, this.progress, this.normalize);

  DateTime lastWatchedOf(Video v) =>
      lastWatched[normalize(v.uri)] ?? DateTime.fromMillisecondsSinceEpoch(0);

  /// 0 = never opened, 1 = part-way through, 2 = finished.
  ///
  /// This is the order MX Player's "Status" sort implies and the one that is
  /// useful in practice: what you have not started, then what you are in the
  /// middle of, then what you are done with. Ninety-five percent counts as
  /// finished because end credits mean nobody watches the last few percent,
  /// and a file left at 99% would otherwise sort away from the finished pile
  /// it belongs to.
  int statusOf(Video v) {
    final p = progress[normalize(v.uri)];
    if (p == null || p <= 0.0) {
      return lastWatched.containsKey(normalize(v.uri)) ? 1 : 0;
    }
    return p >= 0.95 ? 2 : 1;
  }
}

/// File extension, lower-cased, without the dot. Empty when there isn't one.
String _extensionOf(Video v) {
  final name = v.title.isNotEmpty ? v.title : v.uri;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  final ext = name.substring(dot + 1).toLowerCase();
  // Guard against a dot in a folder name rather than the file name.
  return ext.length <= 5 && !ext.contains('/') ? ext : '';
}

List<Video> _sortVideos(
  List<Video> videos,
  LibraryPreferences prefs, [
  _WatchIndex? watch,
]) {
  final sorted = List<Video>.from(videos);
  switch (prefs.sortBy) {
    case SortBy.title:
      sorted.sort((a, b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      break;
    case SortBy.date:
      sorted.sort((a, b) {
        final ad = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bd = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ad.compareTo(bd);
      });
      break;
    case SortBy.length:
      sorted.sort((a, b) => a.duration.compareTo(b.duration));
      break;
    case SortBy.size:
      sorted.sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
      break;
    case SortBy.resolution:
      sorted.sort((a, b) => a.height.compareTo(b.height));
      break;
    case SortBy.playedTime:
      // Oldest-watched first, matching every other ascending sort here; the
      // direction toggle flips it to most-recently-watched. Never-watched
      // files carry epoch, so they group at the "longest ago" end.
      if (watch != null) {
        sorted.sort((a, b) =>
            watch.lastWatchedOf(a).compareTo(watch.lastWatchedOf(b)));
      } else {
        sorted.sort((a, b) {
          final ad = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bd = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          return ad.compareTo(bd);
        });
      }
      break;
    case SortBy.status:
      if (watch != null) {
        sorted.sort((a, b) {
          final c = watch.statusOf(a).compareTo(watch.statusOf(b));
          // Ties broken by title so the order within each group is stable
          // and predictable rather than whatever the scan happened to give.
          return c != 0
              ? c
              : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
      } else {
        sorted.sort((a, b) =>
            a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      }
      break;
    case SortBy.type:
      sorted.sort((a, b) {
        final c = _extensionOf(a).compareTo(_extensionOf(b));
        return c != 0
            ? c
            : a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
      break;
    case SortBy.frameRate:
      // Frame rate is not in the media index, and probing every file in a
      // folder to find it is a feature in its own right. Until it exists this
      // falls back to date rather than silently claiming to have sorted.
      sorted.sort((a, b) {
        final ad = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bd = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ad.compareTo(bd);
      });
      break;
    case SortBy.path:
      sorted.sort((a, b) =>
          a.folderPath.toLowerCase().compareTo(b.folderPath.toLowerCase()));
      break;
  }
  // Default: ascending. For "Newest first" reverse.
  if (prefs.direction == SortDirection.newestFirst) {
    return sorted.reversed.toList();
  }
  return sorted;
}

// Phase 12: Search history (recent search queries)
class SearchHistoryNotifier extends StateNotifier<List<String>> {
  static const _kKey = 'search_history_v1';
  static const int _maxEntries = 10;

  SearchHistoryNotifier() : super(const []) {
    _load();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    state = sp.getStringList(_kKey) ?? const [];
  }

  Future<void> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final list = [...state];
    list.remove(q); // move to top if exists
    list.insert(0, q);
    if (list.length > _maxEntries) list.removeRange(_maxEntries, list.length);
    state = list;
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_kKey, list);
  }

  Future<void> clear() async {
    state = const [];
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kKey);
  }
}

final searchHistoryProvider =
    StateNotifierProvider<SearchHistoryNotifier, List<String>>((ref) {
  return SearchHistoryNotifier();
});
