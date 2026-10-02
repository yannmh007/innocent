import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../data/api/download_plan.dart';
import '../data/api/event_sender.dart';
import '../data/api/offline_downloader.dart';
import '../data/api/offline_library.dart' show OfflineLibrary;
import '../data/device_identity.dart';
import '../domain/access_policy.dart';
import '../domain/byte_size.dart';
import '../domain/offline_key.dart';
import '../domain/viewer.dart';
import '../domain/video_content.dart';
import 'account_provider.dart';
import 'video_hub_provider.dart';
import 'video_hub_theme.dart';
import 'widgets/download_action.dart';

/// Album downloads: one photo or clip at a time, or everything that is not on
/// the phone yet.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT THE VIEWER SEES, AND THE ONE RULE BEHIND ALL OF IT
/// ═══════════════════════════════════════════════════════════════════════
///
///   * Nothing of the album on the phone → "Download all".
///   * Everything on the phone → "Downloaded", dimmed. There is nothing left
///     to press for.
///   * Some of it on the phone → "Download" and "+2 Video". In practice this is
///     an album the viewer downloaded before the admin added to it, and the
///     button fetches ONLY what is new — the two clips, not the album again.
///
/// The rule: whether something is downloaded is worked out from what the album
/// lists now and what is on the shelf now, every time — see
/// [AlbumOfflineStatus]. Nothing records "this album is downloaded", so
/// nothing can go on saying it after the album has changed.

/// Shelf keys of everything this phone holds for [titleId].
///
/// Re-read whenever the shelf is written, whoever wrote it — this album's
/// button, the viewer, a resume on the Downloads screen, the automatic one at
/// launch — so a tile's tick appears the moment its file does.
final albumHeldKeysProvider =
    FutureProvider.autoDispose.family<Set<String>, String>((ref, titleId) async {
  final rows = await ref.watch(offlineLibraryProvider).forTitle(titleId);
  // Subscribed AFTER the read: [OfflineLibrary.forTitle] may itself correct a
  // stale row, and listening first would answer that write with a second read.
  void changed() => ref.invalidateSelf();
  OfflineLibrary.shelf.addListener(changed);
  ref.onDispose(() => OfflineLibrary.shelf.removeListener(changed));
  return <String>{for (final r in rows) r.key};
});

/// Which items of [content]'s album this viewer may download.
///
/// THE SAME TWO QUESTIONS THE REST OF THE APP ASKS, in the same table: may
/// this viewer download this title at all ([AccessPolicy.canDownload]), and may
/// they open this item ([AccessPolicy.canOpenItem]). A locked clip is not
/// "missing" — counting it would offer a free viewer "+3 Video" they cannot
/// have, and the button would fail on the server for each of them.
bool Function(AlbumItem) albumDownloadable(
  AccessPolicy policy,
  ViewerTier tier,
  VideoContent content,
) {
  if (!policy.canDownload(content, tier)) return (_) => false;
  final ordinals = AccessPolicy.photoOrdinalsOf(content.items);
  final ordinalOf = <String, int>{
    for (var i = 0; i < content.items.length; i++)
      content.items[i].id: ordinals[i],
  };
  return (item) {
    // A photo needs a public address to fetch; a clip is asked for by id.
    if (!item.isVideo && !item.source.locator.startsWith('http')) return false;
    return policy.canOpenItem(
      parent: content,
      item: item,
      photoOrdinal: ordinalOf[item.id] ?? -1,
      tier: tier,
    );
  };
}

final albumDownloadsProvider = Provider<AlbumDownloads>((ref) {
  return AlbumDownloads(ref);
});

/// Starts, stops and deletes album items.
///
/// HELD BY A PROVIDER, NOT BY A WIDGET, because an album download outlives the
/// screen it was started from: the viewer taps Download all and goes back to
/// browsing, and the tidying up afterwards — refreshing the shelf, the storage
/// line, the pending list — must still happen with no screen there to do it.
class AlbumDownloads {
  AlbumDownloads(this._ref);

  final Ref _ref;

  OfflineDownloader get _downloader => _ref.read(offlineDownloaderProvider);

  /// Fetches [items] of [content]. Photos first — they take a second each and
  /// make the album visibly fill — then clips, queued behind any film already
  /// downloading.
  ///
  /// Returns how many FAILED. A pause is not a failure, and nor is an item that
  /// was already on its way.
  ///
  /// [confirmVideo] is the per-clip size question, asked when the response
  /// headers arrive. Null means it was already asked for the whole batch.
  Future<int> fetch({
    required VideoContent content,
    required List<AlbumItem> items,
    required DownloadNotices notices,
    Future<bool> Function(int totalBytes, int freeBytes)? confirmVideo,
  }) async {
    final deviceId = await DeviceIdentity.get();
    final jobs = <Future<bool>>[];
    for (final item in items) {
      if (item.isVideo) continue;
      String? error;
      jobs.add(_downloader
          .downloadPhoto(
            content: content,
            assetId: item.id,
            url: item.source.locator,
            onProgress: (p) => error ??= p.error,
          )
          .then((got) => got != null || error == null));
    }
    for (final item in items) {
      if (!item.isVideo) continue;
      String? error;
      final assetId = offlineAssetIdOf(item);
      jobs.add(_downloader
          .download(
            content: content,
            // The album's copy of the film is fetched AS the film: same key,
            // same file, same row the title's own Download button reads.
            source: OfflineDownloader.sourceFor(content, assetId),
            assetId: assetId,
            deviceId: deviceId,
            notices: notices,
            confirmSize: confirmVideo ?? _alreadyAgreed,
            onProgress: (p) => error ??= p.error,
          )
          .then((got) => got != null || error == null));
    }
    final results = await Future.wait(jobs);
    _ref.invalidate(offlineItemsProvider);
    _ref.invalidate(offlinePendingProvider);
    _ref.invalidate(offlineStorageProvider);
    return results.where((ok) => !ok).length;
  }

  static Future<bool> _alreadyAgreed(int totalBytes, int freeBytes) async =>
      true;

  /// Pauses every item of [items] that is downloading. Part files are kept,
  /// exactly as the film's Pause keeps them.
  void pause(VideoContent content, Iterable<AlbumItem> items) {
    for (final item in items) {
      final key = albumItemKey(content.id, item);
      if (_downloader.isRunning(key)) _downloader.cancel(key);
    }
  }

  /// True while any of [items] is downloading or waiting its turn.
  bool anyRunning(VideoContent content, Iterable<AlbumItem> items) =>
      items.any((i) => _downloader.isRunning(albumItemKey(content.id, i)));

  /// Deletes one item from the phone.
  Future<void> drop(String key) async {
    _downloader.cancel(key);
    await _ref.read(offlineLibraryProvider).drop(key);
    _ref.invalidate(offlineItemsProvider);
    _ref.invalidate(offlineStorageProvider);
  }

  /// Deletes every album item [titleId] has on the phone. The FILM STAYS: it
  /// has its own row and its own Delete, and somebody clearing out photos has
  /// not asked to lose a two-hour download.
  Future<void> dropAlbum(String titleId) async {
    final library = _ref.read(offlineLibraryProvider);
    for (final row in await library.forTitle(titleId)) {
      if (row.isFilm) continue;
      _downloader.cancel(row.key);
      await library.drop(row.key);
    }
    _ref.invalidate(offlineItemsProvider);
    _ref.invalidate(offlineStorageProvider);
  }
}

/// Photos alone under this size are fetched without a question, as Telegram
/// does: asking "5 photos, 3 MB?" is friction about nothing.
const int _askAbovePhotoBytes = 25 * 1024 * 1024;

/// "Download all" / "+2 Video": asks once, then fetches what is missing.
Future<void> downloadAlbumMissing(
  BuildContext context,
  WidgetRef ref, {
  required VideoContent content,
  required AlbumOfflineStatus status,
}) async {
  final items = status.missing;
  if (items.isEmpty) return;
  final s = AppStrings.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final library = ref.read(offlineLibraryProvider);
  final free = await library.freeBytes();
  if (!context.mounted) return;

  // ROOM FIRST, before a byte is spent, when the sizes are known. A batch that
  // cannot fit would otherwise fill the phone with the first half of it.
  if (free >= 0 &&
      status.missingBytes > 0 &&
      !hasRoomFor(freeBytes: free, totalBytes: status.missingBytes)) {
    messenger?.showSnackBar(SnackBar(content: Text(s.vhDownloadNoSpace)));
    return;
  }

  final videos = status.missingVideos;
  final photos = status.missingPhotos;
  final needsAsk = videos > 0 ||
      !status.sizeKnown ||
      status.missingBytes > _askAbovePhotoBytes;
  if (needsAsk) {
    final what = <String>[
      if (videos > 0) s.vhAlbumVideos(videos),
      if (photos > 0) s.vhAlbumPhotos(photos),
    ].join(' + ');
    final freeText = free < 0 ? '—' : formatBytes(free);
    final ok = await askDownloadSize(
      context,
      title: content.title,
      body: (s) => status.missingBytes > 0
          // A lower bound is said as one: "1.2 GB+" when an item's size is
          // not recorded, rather than a precise-looking number that is short.
          ? s.vhAlbumAsk(
              what,
              '${formatBytes(status.missingBytes)}${status.sizeKnown ? '' : '+'}',
              freeText,
            )
          : s.vhAlbumAskNoSize(what, freeText),
    );
    if (!ok || !context.mounted) return;
  }

  logEvent(ref, Ev.downloadStart, titleId: content.id, meta: <String, dynamic>{
    'album': true,
    'videos': videos,
    'photos': photos,
    if (status.hasNew) 'new': true,
  });
  final failed = await ref.read(albumDownloadsProvider).fetch(
        content: content,
        items: items,
        notices: DownloadNotices(
          waiting: s.vhDownloadWaitingSignal,
          ready: s.vhDownloadReadyOffline,
        ),
      );
  // The root messenger outlives the screen, so this still reaches somebody who
  // tapped Download all and went back to browsing.
  if (failed > 0) {
    messenger?.showSnackBar(SnackBar(content: Text(s.vhAlbumSomeFailed(failed))));
  }
}

/// One photo or clip, from the viewer.
Future<void> downloadAlbumItem(
  BuildContext context,
  WidgetRef ref, {
  required VideoContent content,
  required AlbumItem item,
}) async {
  final s = AppStrings.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  logEvent(ref, Ev.downloadStart,
      titleId: content.id,
      assetId: item.isVideo ? item.id : null,
      meta: <String, dynamic>{'album': true, 'kind': item.kind.name});
  final failed = await ref.read(albumDownloadsProvider).fetch(
        content: content,
        items: <AlbumItem>[item],
        notices: DownloadNotices(
          waiting: s.vhDownloadWaitingSignal,
          ready: s.vhDownloadReadyOffline,
        ),
        // A clip is asked about on its own, with its own size, exactly like
        // the film: it can be a gigabyte.
        confirmVideo: (total, free) async {
          if (!context.mounted) return true;
          return askDownloadSize(
            context,
            title: content.title,
            body: (s) => s.vhDownloadSizeAsk(
              formatBytes(total),
              free < 0 ? '—' : formatBytes(free),
            ),
          );
        },
      );
  if (failed > 0) {
    messenger?.showSnackBar(SnackBar(content: Text(s.vhUnavailable)));
  }
}

/// The album's own Download button, beside its heading.
class AlbumDownloadButton extends ConsumerWidget {
  final VideoContent content;

  const AlbumDownloadButton({super.key, required this.content});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(accessPolicyProvider);
    final tier = ref.watch(viewerProvider).tier;
    // Hidden, not disabled, for a viewer who cannot download — the same rule
    // as the film's button, for the same reason.
    if (content.items.isEmpty || !policy.canDownload(content, tier)) {
      return const SizedBox.shrink();
    }
    final held = ref.watch(albumHeldKeysProvider(content.id)).valueOrNull;
    // Nothing until the shelf has been read: one frame of "Download all" over
    // an album that is already on the phone invites a tap that does nothing.
    if (held == null) return const SizedBox(height: 32);
    final can = albumDownloadable(policy, tier, content);
    final status = albumOfflineStatus(
      titleId: content.id,
      items: content.items,
      heldKeys: held,
      canDownload: can,
    );
    if (status.total == 0) return const SizedBox.shrink();
    final downloads = ref.read(albumDownloadsProvider);
    final downloader = ref.read(offlineDownloaderProvider);

    return ValueListenableBuilder<int>(
      valueListenable: downloader.activity,
      builder: (context, _, __) {
        final s = AppStrings.of(context);
        final mine = content.items.where(can).toList(growable: false);
        if (downloads.anyRunning(content, mine)) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  value: status.total == 0 ? null : status.held / status.total,
                  strokeWidth: 2,
                  color: VH.textSecondary,
                  backgroundColor: VH.surface2,
                ),
              ),
              const SizedBox(width: VH.s2),
              Text(s.vhAlbumProgress(status.held, status.total),
                  key: const ValueKey('album-dl-progress'),
                  style: VH.meta.copyWith(fontSize: 12)),
              TextButton(
                key: const ValueKey('album-dl-pause'),
                onPressed: () => downloads.pause(content, mine),
                child: Text(s.vhDownloadPause,
                    style: VH.meta.copyWith(fontSize: 12)),
              ),
            ],
          );
        }
        if (status.complete) {
          // DIMMED, AND NOT A BUTTON. Everything is here; there is nothing to
          // press for. Deleting lives on the Downloads screen, where the space
          // it would free is shown.
          return Row(
            key: const ValueKey('album-dl-done'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.download_done_rounded,
                  size: 17, color: VH.textTertiary),
              const SizedBox(width: 5),
              Text(s.vhAlbumDownloaded,
                  style: VH.meta.copyWith(
                      fontSize: 12.5, color: VH.textTertiary)),
            ],
          );
        }
        final news = <String>[
          if (status.missingVideos > 0) s.vhAlbumPlusVideos(status.missingVideos),
          if (status.missingPhotos > 0) s.vhAlbumPlusPhotos(status.missingPhotos),
        ];
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (status.hasNew)
              Container(
                key: const ValueKey('album-dl-new'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: VH.surface2,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(news.join(' · '),
                    style: VH.badge.copyWith(color: VH.textPrimary)),
              ),
            TextButton.icon(
              key: const ValueKey('album-dl-start'),
              onPressed: () => downloadAlbumMissing(context, ref,
                  content: content, status: status),
              icon: const Icon(Icons.download_outlined,
                  size: 18, color: VH.textSecondary),
              label: Text(
                status.hasNew ? s.vhAlbumDownloadNew : s.vhAlbumDownloadAll,
                style: VH.meta.copyWith(fontSize: 12.5),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The small mark on an album tile: a tick when the item is on the phone, a
/// ring while it is arriving, nothing otherwise.
class AlbumItemBadge extends ConsumerWidget {
  final VideoContent content;
  final AlbumItem item;

  const AlbumItemBadge({super.key, required this.content, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final held = ref.watch(albumHeldKeysProvider(content.id)).valueOrNull;
    if (held == null) return const SizedBox.shrink();
    final key = albumItemKey(content.id, item);
    final downloader = ref.read(offlineDownloaderProvider);
    return ValueListenableBuilder<int>(
      valueListenable: downloader.activity,
      builder: (context, _, __) {
        final running = downloader.isRunning(key);
        if (!running && !held.contains(key)) return const SizedBox.shrink();
        return Container(
          width: 20,
          height: 20,
          decoration: const BoxDecoration(
            color: Color(0x99000000),
            shape: BoxShape.circle,
          ),
          padding: const EdgeInsets.all(3),
          child: running
              ? const CircularProgressIndicator(
                  strokeWidth: 1.6, color: Colors.white)
              : const Icon(Icons.download_done_rounded,
                  size: 14, color: Colors.white),
        );
      },
    );
  }
}

/// The album viewer's per-item control: save this one, stop it, or delete it.
class AlbumItemDownloadButton extends ConsumerWidget {
  final VideoContent content;
  final AlbumItem item;

  const AlbumItemDownloadButton({
    super.key,
    required this.content,
    required this.item,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(accessPolicyProvider);
    final tier = ref.watch(viewerProvider).tier;
    if (!albumDownloadable(policy, tier, content)(item)) {
      return const SizedBox.shrink();
    }
    final held = ref.watch(albumHeldKeysProvider(content.id)).valueOrNull;
    if (held == null) return const SizedBox(width: 48);
    final key = albumItemKey(content.id, item);
    final downloader = ref.read(offlineDownloaderProvider);
    final s = AppStrings.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: downloader.activity,
      builder: (context, _, __) {
        if (downloader.isRunning(key)) {
          return IconButton(
            key: ValueKey('item-dl-running-${item.id}'),
            tooltip: s.vhDownloadPause,
            onPressed: () => downloader.cancel(key),
            icon: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: VH.textPrimary),
            ),
          );
        }
        if (held.contains(key)) {
          return IconButton(
            key: ValueKey('item-dl-done-${item.id}'),
            tooltip: s.vhSavedOffline,
            onPressed: () => _confirmDelete(context, ref, key),
            icon: const Icon(Icons.download_done_rounded,
                color: VH.textPrimary),
          );
        }
        return IconButton(
          key: ValueKey('item-dl-${item.id}'),
          tooltip: s.vhSaveOffline,
          onPressed: () =>
              downloadAlbumItem(context, ref, content: content, item: item),
          icon: const Icon(Icons.download_outlined, color: VH.textPrimary),
        );
      },
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, String key) async {
    final s = AppStrings.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VH.surface1,
        content: Text(s.vhDeleteItemBody, style: VH.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              s.delete,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await ref.read(albumDownloadsProvider).drop(key);
  }
}
