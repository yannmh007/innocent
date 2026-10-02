import 'video_content.dart';

/// The shelf key for one downloadable thing.
///
/// THE TITLE ID FOR THE FILM, `<title>.<asset>` FOR AN ALBUM ITEM. The film
/// keeps the bare title id it has always had, so every row, part file and
/// resume point written before albums could be downloaded still means exactly
/// what it meant. An album item gets its own key because a title is no longer
/// one file: an album of five photos and four clips is nine things on the
/// shelf, each downloaded, verified and deleted on its own.
///
/// The album's copy of the film (`AlbumItem.isMain`) is NOT an album item
/// here — the caller passes no asset id for it — so tapping Download on the
/// film and "Download all" on its album fetch the same file once.
String offlineKeyFor(String titleId, {String? assetId}) =>
    (assetId == null || assetId.isEmpty) ? titleId : '$titleId.$assetId';

/// The asset id an album item is downloaded under: null for the album's copy
/// of the film, which shares the film's key — see [offlineKeyFor].
String? offlineAssetIdOf(AlbumItem item) => item.isMain ? null : item.id;

/// The shelf key of one album item.
String albumItemKey(String titleId, AlbumItem item) =>
    offlineKeyFor(titleId, assetId: offlineAssetIdOf(item));

/// Where an album stands against what this phone holds of it.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY "DOWNLOADED" IS COMPUTED, NEVER RECORDED
/// ═══════════════════════════════════════════════════════════════════════
///
/// An album is not a file. The admin adds two clips next week, or swaps a photo
/// for a better one, and an album that was "downloaded" on Monday is not on
/// Friday. A flag written when the last item finished would go on saying so —
/// and the viewer, offline on a bus, finds out by tapping the two clips that
/// were never fetched.
///
/// So the answer is worked out every time from the two facts that are always
/// current: what the album lists NOW, and which of those items have a file on
/// the shelf. A replaced item has a new asset id, so it reads as missing on its
/// own; an item that was removed is simply no longer listed. Nothing needs
/// invalidating because nothing was cached.
class AlbumOfflineStatus {
  /// Items this viewer may download that are not on the phone, in album order.
  final List<AlbumItem> missing;

  /// How many downloadable items ARE on the phone.
  final int held;

  /// Bytes the missing items add up to, counting only those whose size the
  /// server reported. See [sizeKnown].
  final int missingBytes;

  /// False when at least one missing item has no recorded size, so
  /// [missingBytes] is a lower bound and must be shown as one.
  final bool sizeKnown;

  const AlbumOfflineStatus({
    required this.missing,
    required this.held,
    required this.missingBytes,
    required this.sizeKnown,
  });

  int get total => held + missing.length;

  /// Every downloadable item is on the phone: the album's button dims.
  bool get complete => total > 0 && missing.isEmpty;

  /// Some of it is here and some is not — almost always because the admin
  /// added to the album after the viewer downloaded it. Drawn as "+2 Video".
  bool get hasNew => held > 0 && missing.isNotEmpty;

  int get missingVideos => missing.where((i) => i.isVideo).length;
  int get missingPhotos => missing.length - missingVideos;
}

/// Works out [AlbumOfflineStatus] for [items].
///
/// [canDownload] says which items this viewer may download at all — a locked
/// clip is neither "missing" nor counted, or a free viewer would be offered
/// "+3 Video" they cannot have. [heldKeys] are the shelf keys of everything
/// held for this title ([OfflineItem.key]).
AlbumOfflineStatus albumOfflineStatus({
  required String titleId,
  required List<AlbumItem> items,
  required Set<String> heldKeys,
  required bool Function(AlbumItem item) canDownload,
}) {
  final missing = <AlbumItem>[];
  var held = 0;
  var bytes = 0;
  var known = true;
  final seen = <String>{};
  for (final item in items) {
    if (!canDownload(item)) continue;
    final key = albumItemKey(titleId, item);
    // One file per key. Two rows naming the film would otherwise count it as
    // two items, and "4 / 5 downloaded" with nothing left to fetch.
    if (!seen.add(key)) continue;
    if (heldKeys.contains(key)) {
      held++;
      continue;
    }
    missing.add(item);
    final b = item.bytes;
    if (b == null || b <= 0) {
      known = false;
    } else {
      bytes += b;
    }
  }
  return AlbumOfflineStatus(
    missing: missing,
    held: held,
    missingBytes: bytes,
    sizeKnown: known,
  );
}
