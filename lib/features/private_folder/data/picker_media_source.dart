import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path/path.dart' as p;
import '../../../core/localization/app_strings.dart';
/// Fast media enumeration for the Add-Files picker (v0.50.2).
///
/// The first cut of the picker walked the filesystem with `dart:io`
/// recursion, which took many seconds on phones with thousands of files
/// and starved the platform thread (tapping Me mid-scan showed a blank
/// screen). This source instead queries the OS MediaStore through
/// photo_manager — the exact same index the Videos tab uses — so folder
/// lists come back in milliseconds regardless of library size.
///
/// Pure data (no Flutter imports) so providers can call it and dispose
/// cleanly.
class PickerMediaFolder {
  final String id; // MediaStore bucket id (stable key)
  final String path; // absolute folder path
  final String name;
  final int count;
  final PickerAssetType type;
  const PickerMediaFolder({
    required this.id,
    required this.path,
    required this.name,
    required this.count,
    required this.type,
  });
}

class PickerMediaItem {
  final String id; // MediaStore asset id
  final String path;
  final String name;
  final int sizeBytes;
  final DateTime? createdAt;
  const PickerMediaItem({
    required this.id,
    required this.path,
    required this.name,
    required this.sizeBytes,
    this.createdAt,
  });
}

enum PickerAssetType { video, image, audio }

AssetType _assetType(PickerAssetType t) {
  switch (t) {
    case PickerAssetType.video:
      return AssetType.video;
    case PickerAssetType.image:
      return AssetType.image;
    case PickerAssetType.audio:
      return AssetType.audio;
  }
}

RequestType _reqType(PickerAssetType t) {
  switch (t) {
    case PickerAssetType.video:
      return RequestType.video;
    case PickerAssetType.image:
      return RequestType.image;
    case PickerAssetType.audio:
      return RequestType.audio;
  }
}

class PickerMediaSource {
  /// Folder buckets for a media type, resolved to absolute paths, sorted
  /// by name. Returns in milliseconds — only ONE asset per bucket is
  /// touched (to resolve its folder path), never the whole library.
  static Future<List<PickerMediaFolder>> folders(PickerAssetType type) async {
    try {
      return await _folders(type);
    } catch (e, st) {
      // Surface the real reason (was silently swallowed) so an empty
      // Images/Audio tab can be traced from logcat.
      if (kDebugMode) {
        debugPrint('PickerMediaSource.folders($type) failed: $e\n$st');
      }
      return const [];
    }
  }

  static Future<List<PickerMediaFolder>> _folders(PickerAssetType type) async {
    final granted = await _ensurePermission(type);
    if (kDebugMode) {
      debugPrint('PickerMediaSource: permission($type) granted=$granted');
    }
    if (!granted) return const [];

    // No custom filterOption — the Videos tab queries MediaStore with a
    // bare getAssetPathList and works everywhere; adding an OrderOption /
    // needTitle filter made some devices return zero buckets (the empty
    // Images bug). We sort in Dart instead.
    var paths = await PhotoManager.getAssetPathList(
      type: _reqType(type),
      hasAll: false,
    );
    if (kDebugMode) {
      debugPrint('PickerMediaSource: buckets($type) = ${paths.length}');
    }
    // Fallback for OEM MediaStores that return nothing for a narrow type
    // query: ask for ALL media, then keep buckets that actually contain
    // the wanted type.
    if (paths.isEmpty) {
      final all = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
      );
      final kept = <AssetPathEntity>[];
      for (final b in all) {
        final sample = await b.getAssetListRange(start: 0, end: 1);
        if (sample.isNotEmpty &&
            sample.first.type == _assetType(type)) {
          kept.add(b);
        }
      }
      paths = kept;
      if (kDebugMode) {
        debugPrint('PickerMediaSource: fallback buckets($type) = '
            '${paths.length}');
      }
    }

    final out = <PickerMediaFolder>[];
    for (final bucket in paths) {
      final count = await bucket.assetCountAsync;
      if (count == 0) continue;
      String folderPath = bucket.name;
      try {
        final first = await bucket.getAssetListRange(start: 0, end: 1);
        if (first.isNotEmpty) {
          final f = await first.first.file;
          if (f != null) folderPath = p.dirname(f.path);
        }
      } catch (_) {
        // Bucket cover glitch — keep the bucket name as a fallback path.
      }
      out.add(PickerMediaFolder(
        id: bucket.id,
        path: folderPath,
        name: p.basename(folderPath).isEmpty
            ? folderPath
            : p.basename(folderPath),
        count: count,
        type: type,
      ));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// How many items one page of a media bucket holds.
  ///
  /// Sized so the first paint is fast on a slow phone while still filling
  /// more than a screenful — a page smaller than the viewport would make the
  /// list visibly load in steps as the user scrolls.
  static const int kPageSize = 120;

  /// One PAGE of items inside a bucket.
  ///
  /// [page] is zero-based. Returns fewer than [kPageSize] items when the end
  /// of the bucket is reached, which is how the caller knows to stop asking.
  static Future<List<PickerMediaItem>> items(
    String bucketId,
    PickerAssetType type, {
    bool withSize = false,
    int page = 0,
    int pageSize = kPageSize,
  }) async {
    try {
      return await _items(bucketId, type,
          withSize: withSize, page: page, pageSize: pageSize);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('PickerMediaSource.items($type) failed: $e\n$st');
      }
      return const [];
    }
  }

  static Future<List<PickerMediaItem>> _items(
    String bucketId,
    PickerAssetType type, {
    bool withSize = false,
    int page = 0,
    int pageSize = kPageSize,
  }) async {
    if (!await _ensurePermission(type)) return const [];

    var paths = await PhotoManager.getAssetPathList(
      type: _reqType(type),
      hasAll: false,
    );
    if (paths.where((b) => b.id == bucketId).isEmpty) {
      // Same OEM fallback as folders(): the bucket id came from the
      // common-type query, so look there too.
      paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
      );
    }
    final match = paths.where((b) => b.id == bucketId);
    if (match.isEmpty) return const [];
    final bucket = match.first;
    // getAssetListPaged rather than a 0..count range: the range form pulls
    // the entire bucket into memory and then costs one platform call per
    // asset below, which is what made large folders unusable.
    final assets = await bucket.getAssetListPaged(page: page, size: pageSize);

    final out = <PickerMediaItem>[];
    for (final a in assets) {
      final f = await a.file;
      final path = f?.path;
      if (path == null || path.isEmpty) continue;
      int size = 0;
      if (withSize && f != null) {
        try {
          size = await f.length();
        } catch (e) {
          // Size is a nice-to-have; the row hides a 0-byte chip.
          if (kDebugMode) debugPrint('picker_media_source.size: $e');
        }
      }
      out.add(PickerMediaItem(
        id: a.id,
        path: path,
        name: a.title ?? p.basename(path),
        sizeBytes: size,
        createdAt: a.createDateTime,
      ));
    }
    return out;
  }

  /// Request the RIGHT permission for the media type being queried.
  ///
  /// Android 13+ (API 33) split the old READ_EXTERNAL_STORAGE grant into
  /// granular READ_MEDIA_IMAGES / _VIDEO / _AUDIO. photo_manager's
  /// bare `requestPermissionExtend()` asks for a default subset — since
  /// Innocent is a video player the user may only ever have granted the
  /// video permission, so an image/audio query silently returned an empty
  /// MediaStore (the "Nothing here" bug). Passing the matching
  /// [RequestType] makes photo_manager request the correct granular
  /// permission. `hasAccess` is the right gate — it's also true for the
  /// Android 14 "limited / selected media" state, where the user still
  /// sees the items they picked.
  static Future<bool> _ensurePermission(PickerAssetType type) async {
    // Request the permission for the SPECIFIC media type of this tab. On
    // Android 13+ each type (READ_MEDIA_IMAGES / _VIDEO / _AUDIO) is a
    // separate grant; if the app only ever asked for video at startup, a
    // RequestType.common request would report hasAccess=true (video is
    // granted) yet the image query returns nothing. Asking for the exact
    // type makes the OS prompt for THAT permission the first time.
    final ps = await PhotoManager.requestPermissionExtend(
      requestOption: PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: _reqType(type),
          mediaLocation: false,
        ),
      ),
    );
    if (kDebugMode) {
      debugPrint('PickerMediaSource: _ensurePermission($type) '
          'hasAccess=${ps.hasAccess} isAuth=${ps.isAuth}');
    }
    return ps.hasAccess;
  }

  /// The permission state for a specific media type (used by the UI to show
  /// a "grant access" affordance rather than a bare "nothing here").
  static Future<bool> hasPermission([PickerAssetType? type]) async {
    final ps = await PhotoManager.getPermissionState(
      requestOption: PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: type == null ? RequestType.common : _reqType(type),
          mediaLocation: false,
        ),
      ),
    );
    return ps.hasAccess;
  }

}
