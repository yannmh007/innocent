import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart' show MethodChannel;

import 'picker_media_source.dart';

import '../../local_browser/presentation/library_provider.dart';
import '../../../core/localization/app_strings.dart';
/// App-lifetime caches for the Add-Files picker (v0.52).
///
/// The picker used to hold its folder/app lists in local StatefulWidget
/// fields, so every time it was closed and reopened — or the category was
/// switched after a dispose — the MediaStore/PackageManager work ran
/// again and the user waited through a spinner. These are plain
/// (non-autoDispose) FutureProviders, exactly like Local's foldersProvider
/// and Music's allSongsProvider, so the result is computed once and then
/// served instantly for the rest of the session (until the app is killed
/// or the list is explicitly invalidated after an import).
///
/// Riverpod caches the resolved value, so the SECOND open is instant.

/// A shareable app record for the picker's Apps tab.
class PickerAppInfo {
  final String name;
  final String packageName;
  final String apkPath;
  final int sizeBytes;
  final Uint8List? icon;
  const PickerAppInfo({
    required this.name,
    required this.packageName,
    required this.apkPath,
    required this.sizeBytes,
    this.icon,
  });
}

/// Installed user apps (name / package / APK path / size / icon), read once
/// via the mx_clone/apps MethodChannel and cached for the session — the
/// PackageManager scan + icon rasterisation is the slowest of all the
/// picker sources, so caching it is the biggest win.
final pickerAppsProvider = FutureProvider<List<PickerAppInfo>>((ref) async {
  const ch = MethodChannel('mx_clone/apps');
  final raw = await ch.invokeMethod<List<dynamic>>('listApps');
  final out = <PickerAppInfo>[];
  for (final e in raw ?? const []) {
    final m = Map<Object?, Object?>.from(e as Map);
    out.add(PickerAppInfo(
      name: m['name'] as String? ?? '?',
      packageName: m['package'] as String? ?? '',
      apkPath: m['apkPath'] as String? ?? '',
      sizeBytes: (m['size'] as num?)?.toInt() ?? 0,
      icon: m['icon'] as Uint8List?,
    ));
  }
  return out;
});

/// Image folders (MediaStore-backed, milliseconds even for huge libraries).
final pickerImageFoldersProvider =
    FutureProvider<List<PickerMediaFolder>>((ref) async {
  return PickerMediaSource.folders(PickerAssetType.image);
});

/// Audio folders.
final pickerAudioFoldersProvider =
    FutureProvider<List<PickerMediaFolder>>((ref) async {
  return PickerMediaSource.folders(PickerAssetType.audio);
});

/// Video folders (the picker's Videos tab uses the library providers, but
/// this is here for symmetry / future use).
final pickerVideoFoldersProvider =
    FutureProvider<List<PickerMediaFolder>>((ref) async {
  return PickerMediaSource.folders(PickerAssetType.video);
});

/// Paged contents of one media bucket.
///
/// A plain FutureProvider cannot express "and there is more" — it resolves
/// once, with everything, which is precisely the behaviour that made a large
/// Camera folder take tens of seconds to open. This notifier holds the pages
/// loaded so far and knows whether another one exists.
///
/// Not autoDispose, matching the rest of this file: reopening a folder the
/// user already browsed this session is instant, and the pages they scrolled
/// through are still there rather than being fetched again.
class PickerMediaPageState {
  final List<PickerMediaItem> items;
  final bool loading;
  final bool hasMore;

  /// True only for the very first page, so the UI can tell "opening this
  /// folder" (full-screen spinner) from "fetching more" (footer spinner).
  final bool initialLoad;

  const PickerMediaPageState({
    this.items = const [],
    this.loading = true,
    this.hasMore = true,
    this.initialLoad = true,
  });

  PickerMediaPageState copyWith({
    List<PickerMediaItem>? items,
    bool? loading,
    bool? hasMore,
    bool? initialLoad,
  }) =>
      PickerMediaPageState(
        items: items ?? this.items,
        loading: loading ?? this.loading,
        hasMore: hasMore ?? this.hasMore,
        initialLoad: initialLoad ?? this.initialLoad,
      );
}

class PickerMediaPageNotifier extends StateNotifier<PickerMediaPageState> {
  PickerMediaPageNotifier(this._bucketId, this._type)
      : super(const PickerMediaPageState()) {
    loadMore();
  }

  final String _bucketId;
  final PickerAssetType _type;
  int _page = 0;

  /// Guards against the scroll listener firing several times before the
  /// first fetch returns — which would load the same page repeatedly and
  /// show every item two or three times.
  bool _busy = false;

  Future<void> loadMore() async {
    if (_busy || !state.hasMore) return;
    _busy = true;
    if (!state.loading) state = state.copyWith(loading: true);
    try {
      final batch = await PickerMediaSource.items(
        _bucketId,
        _type,
        page: _page,
        // Sizes are now affordable and they were doing real damage by their
        // absence: every media item reported 0 bytes, so the size chip never
        // rendered AND "sort by size" silently did nothing in Videos, Images
        // and Audio — a menu option that appeared to work and did not. It
        // was left lazy because the old code loaded whole buckets, where one
        // `length()` per asset across 5 000 files was genuinely too much.
        // Bounded to a 120-item page, it is 120 stat calls.
        withSize: true,
      );
      if (!mounted) return;
      _page++;
      state = PickerMediaPageState(
        items: [...state.items, ...batch],
        loading: false,
        hasMore: batch.length >= PickerMediaSource.kPageSize,
        initialLoad: false,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('picker_providers.page: $e');
      if (!mounted) return;
      // Stop asking rather than spinning forever on a broken bucket.
      state = state.copyWith(loading: false, hasMore: false,
          initialLoad: false);
    } finally {
      _busy = false;
    }
  }
}

final pickerMediaItemsProvider = StateNotifierProvider.family<
    PickerMediaPageNotifier,
    PickerMediaPageState,
    ({String bucketId, PickerAssetType type})>((ref, arg) {
  return PickerMediaPageNotifier(arg.bucketId, arg.type);
});

/// Mounted storage volumes for the Files browser (internal + SD cards).
final pickerStorageRootsProvider =
    FutureProvider<List<Directory>>((ref) async {
  final roots = <Directory>[];
  final primary = Directory('/storage/emulated/0');
  if (await primary.exists()) roots.add(primary);
  try {
    await for (final e in Directory('/storage').list()) {
      final name = p.basename(e.path);
      if (e is Directory &&
          name != 'emulated' &&
          name != 'self' &&
          RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$').hasMatch(name)) {
        roots.add(e);
      }
    }
  } catch (e) {
    if (kDebugMode) debugPrint('picker_providers.roots: $e');
  }
  if (roots.isEmpty) roots.add(Directory('/storage/emulated/0'));
  return roots;
});

/// Directory listing (folders first, then files) for one directory,
/// cached per absolute path. The Files browser reads these; a directory a
/// user has already visited reopens instantly.
final pickerDirListingProvider =
    FutureProvider.family<List<FileSystemEntity>, String>((ref, dirPath) async {
  // Mirror Local's "Show hidden files and folders" toggle: when it's on, the
  // picker's Files browser reveals dot-prefixed entries too; when off, they're
  // skipped exactly as before.
  final showHidden =
      ref.watch(libraryPreferencesProvider.select((p) => p.showHidden));
  final dir = Directory(dirPath);
  final dirs = <Directory>[];
  final files = <File>[];
  try {
    await for (final e in dir.list(followLinks: false)) {
      final name = p.basename(e.path);
      if (!showHidden && name.startsWith('.')) continue;
      if (e is Directory) {
        dirs.add(e);
      } else if (e is File) {
        files.add(e);
      }
    }
  } catch (e) {
    if (kDebugMode) debugPrint('picker_providers.dir: $e');
  }
  int byName(FileSystemEntity a, FileSystemEntity b) => p
      .basename(a.path)
      .toLowerCase()
      .compareTo(p.basename(b.path).toLowerCase());
  dirs.sort(byName);
  files.sort(byName);
  return [...dirs, ...files];
});
