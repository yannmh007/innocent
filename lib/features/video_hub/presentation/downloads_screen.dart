import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/power/power_policy.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../data/api/offline_downloader.dart';
import '../data/api/offline_library.dart';
import '../data/device_identity.dart';
import '../data/api/watch_while_downloading.dart';
import 'album_downloads.dart';
import 'album_viewer_screen.dart';
import 'playback.dart';
import 'video_hub_provider.dart';
import 'data_saver_panel.dart';
import 'widgets/hub_states.dart';
import 'widgets/poster_image.dart';
import 'widgets/vh_insets.dart';
import '../domain/byte_size.dart';
import '../domain/video_content.dart';
import 'video_hub_theme.dart';
import '../../../core/theme/tab_title.dart';

/// What is kept on this device.
///
/// The Downloads tile on the account screen used to open a "coming soon"
/// message. This is the screen behind it.
///
/// EVERYTHING HERE WORKS WITH NO NETWORK, which is the whole point and the
/// reason the list is built from [OfflineLibrary] rather than from the
/// catalogue: a viewer opening this on a train has no server to ask what a
/// title is called, so the name, the Burmese name and the poster URL were all
/// copied onto the shelf at download time.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final itemsAsync = ref.watch(offlineItemsProvider);

    return Scaffold(
      backgroundColor: VH.canvas,
      appBar: AppBar(
        backgroundColor: VH.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(s.vhLibraryDownloads, style: kAppBarTitleStyle.copyWith(color: VH.textPrimary)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: VH.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: itemsAsync.when(
        // No error state worth its own screen: items() swallows a broken index
        // and returns an empty list, because a shelf that cannot be read looks
        // exactly like an empty one to the person holding the phone.
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => HubEmptyState(
              message: s.vhLibraryDownloadsHint,
              icon: Icons.download_for_offline_outlined),
        data: (items) {
          // UNFINISHED DOWNLOADS ARE PART OF THIS SCREEN, and used to be
          // nowhere at all.
          //
          // On the connection this feature exists for, a film takes an hour or
          // two and being interrupted is the ordinary case, not the unusual
          // one. What was left behind was a `.part` file named by a uuid that
          // nothing in the app could see: the shelf looked empty, the gigabyte
          // was unreclaimable through the UI, and carrying on meant
          // remembering which title it had been and finding it in the
          // catalogue again. The bytes were already paid for. They are the
          // first thing on the screen now.
          final pending = ref.watch(offlinePendingProvider).valueOrNull ??
              const <PendingProgress>[];
          // THE SETTINGS SHOW WHEN THE SHELF IS EMPTY TOO. They used to be
          // drawn only beside a list, so the place the data saver was said to
          // live showed nothing but "no downloads" to everyone who had not
          // downloaded yet — exactly the person deciding whether to.
          final empty = items.isEmpty && pending.isEmpty;
          // WHAT IS LEFT, not only what is taken. Somebody deciding whether
          // to download tonight's film needs the free figure more than the
          // used one, and neither was on this screen.
          final storage = ref.watch(offlineStorageProvider).valueOrNull;
          return ListView(
            padding: EdgeInsets.fromLTRB(
                VH.gutter, VH.s3, VH.gutter, VhInsets.scrollBottom(context)),
            children: <Widget>[
              // ═════════════════════════════════════════════════════════
              // WHAT IS ON THE PHONE FIRST, HOW IT BEHAVES LAST
              // ═════════════════════════════════════════════════════════
              //
              // This screen used to open on its settings — the storage line,
              // the Wi-Fi switch, the whole data saver card — and the films
              // the viewer came for started below the fold. Netflix and
              // YouTube both put the downloads first and the settings in a
              // compact group at the bottom; so does this, now.
              if (storage != null)
                _StorageCard(used: storage.used, free: storage.free),
              // WHY A DOWNLOAD STOPS WHEN THE PHONE IS PUT DOWN, in the one
              // place the person who noticed it is looking. See _BatteryRow.
              const _BatteryRow(),
              if (empty)
                HubEmptyState(
                    message: s.vhLibraryDownloadsHint,
                    icon: Icons.download_for_offline_outlined),
              if (pending.isNotEmpty) ...<Widget>[
                _Section(title: s.vhDownloadsActive, trailing: '${pending.length}'),
                for (final p in pending)
                  _PendingRow(
                    pending: p,
                    languageCode: s.locale.languageCode,
                  ),
              ],
              // FILMS ONE ROW EACH, ALBUMS ONE ROW PER TITLE. Nine photos and
              // clips of one title as nine rows would bury the films, and none
              // of them means anything without the album around it.
              if (items.isNotEmpty) ...<Widget>[
                _Section(
                  title: s.vhDownloadsDone,
                  trailing:
                      '${_shelfRows(items).length} · ${formatBytes(items.fold<int>(0, (a, i) => a + i.bytes))}',
                ),
                for (final entry in _shelfRows(items))
                  if (entry.film != null)
                    _Row(item: entry.film!, languageCode: s.locale.languageCode)
                  else
                    _AlbumRow(
                        items: entry.album, languageCode: s.locale.languageCode),
              ],
              _Section(title: s.vhDownloadsSettings),
              const _SettingsGroup(),
            ],
          );
        },
      ),
    );
  }
}

/// One row of the shelf: a film, or every album item of one title.
typedef _ShelfRow = ({OfflineItem? film, List<OfflineItem> album});

/// The shelf in display order (newest first, as [OfflineLibrary.items] gives
/// it), with each title's album items gathered into the row of the newest one.
List<_ShelfRow> _shelfRows(List<OfflineItem> items) {
  final out = <_ShelfRow>[];
  final albumAt = <String, int>{};
  for (final item in items) {
    if (item.isFilm) {
      out.add((film: item, album: const <OfflineItem>[]));
      continue;
    }
    final at = albumAt[item.titleId];
    if (at == null) {
      albumAt[item.titleId] = out.length;
      out.add((film: null, album: <OfflineItem>[item]));
    } else {
      out[at].album.add(item);
    }
  }
  return out;
}

/// The album items one title has on the phone.
class _AlbumRow extends ConsumerWidget {
  final List<OfflineItem> items;
  final String languageCode;

  const _AlbumRow({required this.items, required this.languageCode});

  OfflineItem get _first => items.first;

  String get _shownTitle {
    if (languageCode != 'my') return _first.title;
    final mm = _first.titleMm?.trim();
    return (mm == null || mm.isEmpty) ? _first.title : mm;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final videos = items.where((i) => !i.isPhoto).length;
    final photos = items.length - videos;
    final bytes = items.fold<int>(0, (sum, i) => sum + i.bytes);
    // The newest photo is the row's picture: it is ON THE PHONE, so it draws
    // with no signal, where the title's poster may not have been kept.
    OfflineItem? cover;
    for (final i in items) {
      if (i.isPhoto && i.sourceUrl != null) {
        cover = i;
        break;
      }
    }
    final art = cover?.sourceUrl ?? _first.posterUrl;
    return _RowShell(
      onTap: () => _open(context, ref),
      thumb: _Thumb(art: art, title: _shownTitle, glyph: Icons.photo_library_outlined),
      title: _shownTitle,
      titleIcon: Icons.photo_library_outlined,
      lines: <Widget>[
        Text(
          <String>[
            if (videos > 0) s.vhAlbumVideos(videos),
            if (photos > 0) s.vhAlbumPhotos(photos),
            formatBytes(bytes),
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: VH.meta.copyWith(fontSize: 12),
        ),
      ],
      trailing: <Widget>[
        _RowMenu(entries: <(IconData, String, VoidCallback, bool)>[
          (Icons.photo_library_outlined, s.vhAlbum, () => _open(context, ref), false),
          (Icons.delete_outline_rounded, s.delete, () => _confirmDelete(context, ref), true),
        ]),
      ],
    );
  }

  /// Opens the album the items belong to, from the catalogue cache when there
  /// is no signal — the viewer then draws every saved photo from the phone and
  /// plays every saved clip from it.
  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final s = AppStrings.of(context);
    VideoContent? content;
    try {
      content = await ref.read(contentRepositoryProvider).getById(_first.titleId);
    } catch (_) {
      content = null;
    }
    if (!context.mounted) return;
    if (content == null || content.items.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.vhOfflineNotHeld)));
      return;
    }
    final keys = <String>{for (final i in items) i.key};
    var start = content.items
        .indexWhere((i) => keys.contains(albumItemKey(content!.id, i)));
    if (start < 0) start = 0;
    final album = content;
    await Navigator.of(context).push(AlbumViewerScreen.route(album, start));
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final s = AppStrings.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VH.surface1,
        title: Text(_shownTitle, style: VH.label),
        content: Text(s.vhAlbumDeleteBody, style: VH.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              s.delete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await ref.read(albumDownloadsProvider).dropAlbum(_first.titleId);
  }
}

class _Row extends ConsumerWidget {
  final OfflineItem item;
  final String languageCode;

  const _Row({required this.item, required this.languageCode});

  String get _shownTitle {
    if (languageCode != 'my') return item.title;
    final mm = item.titleMm?.trim();
    return (mm == null || mm.isEmpty) ? item.title : mm;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    return _RowShell(
      onTap: () => _play(context, ref),
      thumb: _Thumb(art: item.posterUrl, title: _shownTitle, badge: _hms(item.durationS)),
      title: _shownTitle,
      lines: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.offline_pin_rounded, size: 13, color: Color(0xFF2EBD6B)),
            const SizedBox(width: 4),
            Text(formatBytes(item.bytes), style: VH.meta.copyWith(fontSize: 12)),
          ],
        ),
      ],
      trailing: <Widget>[
        _RowMenu(entries: <(IconData, String, VoidCallback, bool)>[
          (Icons.play_arrow_rounded, s.vhPlay, () => _play(context, ref), false),
          (Icons.delete_outline_rounded, s.delete, () => _confirmDelete(context, ref), true),
        ]),
      ],
    );
  }

  /// Opens the local file THROUGH playback.dart, like every other play.
  ///
  /// The first version of this pushed `Routes.player` directly and the
  /// structural checker failed the build for it — correctly. A downloaded
  /// file is the one path where nothing would otherwise stop a viewer whose
  /// subscription ended last week, so it is exactly the path that must not
  /// have its own door. See [playOffline].
  Future<void> _play(BuildContext context, WidgetRef ref) {
    return playOffline(
      context,
      ref,
      path: item.path,
      sealed: item.sealed,
      titleId: item.titleId,
      title: _shownTitle,
      // WHAT IT ACTUALLY WAS, which is not always premium.
      //
      // This used to pass `true` unconditionally, on the strength of a comment
      // claiming nothing free is ever downloaded. `AccessPolicy.canDownload`
      // returns true for a FREE title whatever the viewer's tier, so the
      // Download button is drawn for a free film on an anonymous account — and
      // `playOffline` then asked for the premium capability and put the
      // paywall over it. An hour of mobile data spent on a film the app
      // refused to open, with no way past it but paying for something free.
      premium: item.premium,
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final s = AppStrings.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VH.surface1,
        title: Text(_shownTitle, style: VH.label),
        content: Text(s.vhDeleteDownloadBody, style: VH.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            // The destructive action is coloured from the app's own error
            // role rather than a hex literal invented here — VH has no
            // danger colour, and inventing one would put a second red in
            // the app that drifts from the first.
            child: Text(
              s.delete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await ref.read(offlineLibraryProvider).drop(item.key);
    ref.invalidate(offlineItemsProvider);
    ref.invalidate(offlineStorageProvider);
  }
}


/// One unfinished download: what it is, how far it got, resume or throw away.
class _PendingRow extends ConsumerStatefulWidget {
  final PendingProgress pending;
  final String languageCode;

  const _PendingRow({required this.pending, required this.languageCode});

  @override
  ConsumerState<_PendingRow> createState() => _PendingRowState();
}

class _PendingRowState extends ConsumerState<_PendingRow> {
  /// How much has to be on disk before "watch now" is even offered.
  ///
  /// Eight megabytes. Below that the index is unlikely to have finished
  /// arriving whatever its position, so the button would be there to fail. This
  /// is the cheap gate; [WatchWhileDownloading.open] is the real one.
  static const int _watchFrom = 8 * 1024 * 1024;

  OfflineProgress? _live;
  bool _starting = false;
  bool _opening = false;
  StreamSubscription<OfflineProgress>? _sub;

  PendingDownload get item => widget.pending.item;

  String get _shownTitle {
    if (widget.languageCode != 'my') return item.title;
    final mm = item.titleMm?.trim();
    return (mm == null || mm.isEmpty) ? item.title : mm;
  }

  @override
  void initState() {
    super.initState();
    // Re-attach to a resume that is already running — the viewer can start one
    // and navigate away and back, and a row that forgot would offer to start a
    // second writer on the same file.
    final live = ref.read(offlineDownloaderProvider).watch(item.key);
    if (live != null) {
      _sub = live.listen((p) {
        if (mounted) setState(() => _live = p);
      });
    }
  }

  @override
  void dispose() {
    // Held so it can be cancelled. A listener left running per visit to this
    // screen is a `setState` on a dead widget the next time a download moves.
    _sub?.cancel();
    super.dispose();
  }

  /// Opens a download that has not finished, the way Telegram does.
  ///
  /// THE CHECK HAPPENS HERE AND NOT IN `build`, because it is a read and a
  /// decrypt of the first couple of megabytes and a list must not do that per
  /// frame. So the button is offered on a cheap test and the expensive one
  /// happens on the tap — which means it can say no, and every no says which
  /// no it is. "Not enough yet" and "only once it has finished" are completely
  /// different pieces of news: the first is worth waiting a minute for, and the
  /// second means going and doing something else.
  Future<void> _watchNow(int total) async {
    final s = AppStrings.of(context);
    setState(() => _opening = true);
    try {
      final got = await WatchWhileDownloading.open(
        library: ref.read(offlineLibraryProvider),
        key: item.key,
        total: total,
      );
      if (!mounted) return;
      final url = got.url;
      if (url == null) {
        final text = switch (got.refusal) {
          PartialRefusal.indexAtEnd => s.vhWatchIndexAtEnd,
          PartialRefusal.gone => s.vhWatchGone,
          _ => s.vhWatchNotYet,
        };
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
        return;
      }
      await playPartial(
        context,
        ref,
        url: url,
        titleId: item.titleId,
        title: _shownTitle,
        premium: item.premium,
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// RESUMING NEEDS THE TITLE BACK, and the row deliberately does not hold it.
  ///
  /// What is stored is enough to DRAW the row with no network — a name, a
  /// poster URL — because that is what an offline screen needs. Resuming is a
  /// network operation by definition (a fresh signed URL, a fresh entitlement
  /// check), so fetching the title by id costs nothing that was not already
  /// being spent, and storing a whole catalogue record per pending download
  /// would mean a stale copy of it on disk for ever.
  Future<void> _resume() async {
    final s = AppStrings.of(context);
    setState(() => _starting = true);
    try {
      final content =
          await ref.read(contentRepositoryProvider).getById(item.titleId);
      if (!mounted) return;
      if (content == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(s.vhUnavailable)));
        return;
      }
      final deviceId = await DeviceIdentity.get();
      if (!mounted) return;
      String? failure;
      final done = await ref.read(offlineDownloaderProvider).download(
            content: content,
            source: OfflineDownloader.sourceFor(content, item.assetId),
            deviceId: deviceId,
            assetId: item.assetId,
            notices: DownloadNotices(
              waiting: s.vhDownloadWaitingSignal,
              ready: s.vhDownloadReadyOffline,
            ),
            onProgress: (p) {
              if (p.error != null) failure = p.error;
              if (mounted) setState(() => _live = p);
            },
          );
      if (!mounted) return;
      ref.invalidate(offlineItemsProvider);
      ref.invalidate(offlinePendingProvider);
      ref.invalidate(offlineStorageProvider);
      if (done != null || failure == null) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failure == 'no_space'
            ? s.vhDownloadNoSpace
            : failure == 'gave_up'
                ? s.vhDownloadGaveUp
                : s.vhUnavailable),
      ));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _discard() async {
    final s = AppStrings.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VH.surface1,
        title: Text(_shownTitle, style: VH.label),
        content: Text(s.vhDiscardDownloadBody, style: VH.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              s.delete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    ref.read(offlineDownloaderProvider).cancel(item.key);
    await ref.read(offlineLibraryProvider).discardPending(item.key);
    ref.invalidate(offlinePendingProvider);
    ref.invalidate(offlineStorageProvider);
  }

  /// The one line under the title, which has to carry four different states.
  ///
  /// SPEED AND TIME LEFT WHILE IT RUNS, because that is what somebody deciding
  /// whether to keep waiting needs and the byte count is not. "Waiting for the
  /// connection" while the link is down, because a frozen number reads as a
  /// bug. And how far it got while it is paused, because that is the number
  /// that makes resuming obviously worth it.
  String _line(
    AppStrings s, {
    required OfflineProgress? live,
    required int received,
    required int? total,
  }) {
    final got = total == null
        ? formatBytes(received)
        : '${formatBytes(received)} / ${formatBytes(total)}';
    if (live != null) {
      if (live.waitingForNetwork) return '$got · ${s.vhDownloadWaitingSignal}';
      // Slow on purpose, and saying so: a film is streaming and gets the
      // line first. Without the words this reads as the download breaking.
      if (live.yielding) return '$got · ${s.vhDownloadYielding}';
      final speed = live.bytesPerSecond;
      final left = live.remaining;
      if (speed != null && speed > 0 && left != null) {
        return '$got · ${formatBytes(speed)}/s · ${s.vhDownloadLeft(left)}';
      }
      if (speed != null && speed > 0) {
        return '$got · ${formatBytes(speed)}/s';
      }
      return '$got · ${s.vhDownloadResuming}';
    }
    // PAUSED AND INTERRUPTED READ DIFFERENTLY, because they are different
    // promises. One is waiting for the viewer; the other is waiting for
    // nothing and will pick itself up the next time the app opens with a
    // connection. Telling somebody their download is "Paused" when it is
    // about to carry on invites them to press something they do not need to.
    if (widget.pending.item.pausedByUser) return '$got · ${s.vhDownloadPaused}';
    return '$got · ${s.vhDownloadWillResume}';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    // NARROWED TO NULL RATHER THAN PAIRED WITH A BOOL. `running` is a fact
    // about `live`, and Dart's flow analysis cannot carry it back — so
    // `running ? live.received : ...` does not compile, and writing `live!`
    // to get past that puts a bang next to a value that really can be null.
    final reported = _live;
    final OfflineProgress? live =
        (reported != null && !reported.done && reported.error == null)
            ? reported
            : null;
    final running = live != null;
    // The live figure while a resume is under way, the on-disk figure
    // otherwise. Both are real; the difference is only which is fresher.
    final received = live?.received ?? widget.pending.received;
    final total = live?.total ?? widget.pending.total;
    final double? fraction = (total != null && total > 0)
        ? (received / total).clamp(0.0, 1.0).toDouble()
        : null;

    final canWatch = total != null && received >= _watchFrom;
    return _RowShell(
      thumb: _Thumb(art: item.posterUrl, title: _shownTitle),
      title: _shownTitle,
      lines: <Widget>[
        // THE BYTES ALREADY PAID FOR, on screen. Somebody deciding whether to
        // carry on needs to know they are 700 MB into a 900 MB film and not
        // starting again — that is the whole difference between resuming and
        // giving up.
        Text(
          _line(s, live: live, received: received, total: total),
          style: VH.meta.copyWith(fontSize: 11.5, height: 1.3),
          // Two lines: the status at the end ("paused", "carries on by
          // itself") is the part that says what to do, and one line cut it.
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(VH.rPill),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 3,
            color: running ? VH.accent : VH.textTertiary,
            backgroundColor: VH.surface3,
          ),
        ),
      ],
      trailing: <Widget>[
        const SizedBox(width: VH.s2),
        // ONE MAIN ACTION, in a circle: pause while it runs, resume when it
        // does not. Watching while it arrives and throwing it away are in
        // the menu — three icons in a row squeezed the title to "Myanmar …".
        _CircleAction(
          tooltip: running ? s.vhDownloadPause : s.vhDownloadResume,
          busy: _starting,
          icon: running ? Icons.pause_rounded : Icons.file_download_outlined,
          onTap: running
              ? () => ref.read(offlineDownloaderProvider).cancel(item.key)
              : (_starting ? null : _resume),
        ),
        _RowMenu(entries: <(IconData, String, VoidCallback, bool)>[
          // WATCH IT WHILE IT ARRIVES. Offered from about eight megabytes in,
          // and only when the film's length is known — see _watchNow.
          if (canWatch && !_opening)
            (Icons.play_circle_outline_rounded, s.vhWatchNow, () => _watchNow(total), false),
          (Icons.delete_outline_rounded, s.delete, _discard, true),
        ]),
      ],
    );
  }
}

/// A round button for a row's one main action, with a spinner while busy.
class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.busy = false,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: VH.surface2,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(icon, size: 19, color: VH.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}


/// "Download over Wi-Fi only", with the reason it is off by default.
/// Says why a download stops when the phone is put down, and offers the fix.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE LAST THING STANDING BETWEEN A DOWNLOAD AND FINISHING
/// ═══════════════════════════════════════════════════════════════════════
///
/// `OfflineService` already declares the transfer to Android, holds a partial
/// WakeLock and a WifiLock, and survives a swipe out of recents. On stock
/// Android that is the whole answer and this row never appears.
///
/// It is not the answer on the phones this app is used on. Xiaomi, Oppo, Vivo,
/// Realme and Huawei ship battery managers that freeze or kill backgrounded
/// processes on a timer, by default, foreground service or not. The download
/// stops, and the viewer — on the mobile connection that made downloading the
/// right answer in the first place — is given no reason and concludes the app
/// is broken. Nothing in an app can override that setting. What it can do is
/// the two things this row is:
///
///   SAY SO, where somebody looking at a stalled download will read it. A
///   message in Settings would be read by nobody; this is on the screen they
///   are already on.
///
///   OFFER THE ONE TAP. Android has a standard dialog for the Doze exemption
///   and the user's answer is the only thing that changes the outcome.
///
/// TWO STATES AND TWO DIFFERENT BUTTONS, because offering the wrong one wastes
/// the only tap anybody will give. `restricted` means background work has been
/// switched off for this app by hand and the exemption dialog does not touch
/// it — the only honest action there is to open the page that holds the
/// switch.
///
/// DRAWN ONLY WHEN THERE IS SOMETHING TO SAY. A phone that is already exempt
/// and unrestricted gets nothing, and an unreadable platform reports the
/// permissive answer for the same reason: a card telling somebody to fix a
/// problem they do not have is worse than silence, because what is on their
/// screen is a download that works.
class _BatteryRow extends StatefulWidget {
  const _BatteryRow();

  @override
  State<_BatteryRow> createState() => _BatteryRowState();
}

class _BatteryRowState extends State<_BatteryRow> with WidgetsBindingObserver {
  PowerState _state = PowerState.unknown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // THE ANSWER CHANGES WHILE THIS SCREEN IS IN THE BACKGROUND, which is the
    // whole shape of the interaction: the button opens a system dialog, the
    // app is backgrounded, the user grants it, and the app comes back. Without
    // this the row would still be telling them to fix what they have just
    // fixed.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final next = await PowerPolicy.read(fresh: true);
    if (!mounted) return;
    setState(() => _state = next);
  }

  @override
  Widget build(BuildContext context) {
    if (!_state.restrictsDownloads) return const SizedBox.shrink();
    final s = AppStrings.of(context);
    // `restricted` first: it is the harder refusal and the dialog cannot lift
    // it, so offering the dialog would be a tap that changes nothing.
    final hard = _state.restricted;
    return Container(
      margin: const EdgeInsets.only(bottom: VH.s3),
      padding: const EdgeInsets.all(VH.s3),
      decoration: BoxDecoration(
        color: VH.surface2,
        borderRadius: BorderRadius.circular(VH.s2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.battery_alert_outlined,
                  size: 18, color: VH.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hard ? s.vhBatteryBlockedTitle : s.vhBatteryDozeTitle,
                  style: VH.label.copyWith(fontSize: 13.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            hard
                ? s.vhBatteryBlockedBody
                : s.vhBatteryDozeBody(
                    // Named, because the page that actually matters is called
                    // something different on every one of these ROMs and
                    // "your phone" tells nobody where to look.
                    _state.manufacturer.isEmpty ? '—' : _state.manufacturer),
            style: VH.meta.copyWith(fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                if (hard) {
                  await PowerPolicy.openSettings();
                } else {
                  await PowerPolicy.requestExemption();
                }
                // The lifecycle callback re-reads when the app comes back, so
                // there is nothing to poll for here.
              },
              child: Text(
                hard ? s.vhBatteryOpenSettings : s.vhBatteryAllow,
                style: const TextStyle(
                  color: VH.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WifiOnlyRow extends ConsumerWidget {
  const _WifiOnlyRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final on = ref.watch(playerSettingsProvider).get(
          PlayerSetting.downloadWifiOnly,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(VH.s3, VH.s2, VH.s2, VH.s2),
      child: Row(
        children: <Widget>[
          const Icon(Icons.wifi_rounded, size: 20, color: VH.textSecondary),
          const SizedBox(width: VH.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(s.vhDownloadWifiOnly,
                    style: VH.label.copyWith(fontSize: 13.5)),
                const SizedBox(height: 1),
                // THE HINT SAYS WHY IT IS OFF. A switch whose default looks
                // wrong invites somebody to "fix" it, and turning this on is
                // exactly the wrong move for a viewer with no wifi — their
                // downloads would then wait for something that never comes.
                Text(s.vhDownloadWifiOnlyHint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: VH.meta.copyWith(fontSize: 11, height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: VH.s2),
          Switch(
            value: on,
            onChanged: (v) => ref
                .read(playerSettingsProvider.notifier)
                .setValue(PlayerSetting.downloadWifiOnly, v),
          ),
        ],
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════
// THE PIECES THE SCREEN IS BUILT FROM
// ═══════════════════════════════════════════════════════════════════════

/// Space on the phone: what the downloads take, what is left, as one bar.
class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.used, required this.free});
  final int used;
  final int free;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final known = free >= 0;
    final share = known && used + free > 0 ? used / (used + free) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: VH.s2),
      padding: const EdgeInsets.fromLTRB(VH.s3, VH.s3, VH.s3, VH.s3),
      decoration: BoxDecoration(
        color: VH.surface1,
        borderRadius: BorderRadius.circular(VH.rCard),
        border: Border.all(color: VH.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.sd_storage_outlined, size: 17, color: VH.textSecondary),
              const SizedBox(width: VH.s2),
              // One line when both fit, the figures under the title when not
              // (Burmese in a large font on a narrow phone squeezed the
              // title to a letter a line beside them).
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: VH.s2,
                  runSpacing: 2,
                  children: <Widget>[
                    Text(s.vhDownloadStorageLine,
                        style: VH.label.copyWith(fontSize: 13)),
                    Text(
                      s.vhDownloadStorage(
                          formatBytes(used), known ? formatBytes(free) : '—'),
                      style: VH.meta
                          .copyWith(fontSize: 11.5, color: VH.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: VH.s2),
          ClipRRect(
            borderRadius: BorderRadius.circular(VH.rPill),
            child: LinearProgressIndicator(
              value: share == null ? 0 : share.clamp(0.02, 1.0),
              minHeight: 5,
              color: VH.accent,
              backgroundColor: VH.surface3,
            ),
          ),
        ],
      ),
    );
  }
}

/// A section's heading, with a count or total at the right.
class _Section extends StatelessWidget {
  const _Section({required this.title, this.trailing});
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, VH.s4, 2, VH.s2),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(title, style: VH.heading.copyWith(fontSize: 15.5))),
          if (trailing != null)
            Text(trailing!, style: VH.meta.copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}

/// The artwork beside a row: 16:9, as the films are, with an optional label
/// (a running time) in its corner.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.art, required this.title, this.glyph, this.badge});
  final String? art;
  final String title;
  final IconData? glyph;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 104,
      height: 58,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            PosterImage(
              mediaRef: art == null ? MediaRef.none : MediaRef(provider: 'url', locator: art!),
              title: title,
              glyph: glyph ?? Icons.movie_outlined,
            ),
            if (badge != null && badge!.isNotEmpty)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xB3000000),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(badge!,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w600)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One shelf row's frame: artwork, title, the lines under it, and actions.
class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.thumb,
    required this.title,
    required this.lines,
    required this.trailing,
    this.onTap,
    this.titleIcon,
  });
  final Widget thumb;
  final String title;
  final IconData? titleIcon;
  final List<Widget> lines;
  final List<Widget> trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VH.rControl),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            thumb,
            const SizedBox(width: VH.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (titleIcon != null) ...<Widget>[
                        Icon(titleIcon, size: 14, color: VH.textTertiary),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: VH.label.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  ...lines,
                ],
              ),
            ),
            ...trailing,
          ],
        ),
      ),
    );
  }
}

/// The row's ⋮ — the actions that are not the main one, Delete above all.
///
/// Behind a menu rather than a bin icon on every row: a one-tap destructive
/// control beside every film was the biggest thing on each line, and the
/// easiest one to hit by accident while scrolling.
class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.entries});
  final List<(IconData, String, VoidCallback, bool)> entries; // icon, label, action, danger

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '',
      icon: const Icon(Icons.more_vert_rounded, color: VH.textTertiary, size: 20),
      color: VH.surface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(VH.rControl)),
      onSelected: (i) => entries[i].$3(),
      itemBuilder: (context) => <PopupMenuEntry<int>>[
        for (final (i, e) in entries.indexed)
          PopupMenuItem<int>(
            value: i,
            height: 42,
            child: Row(
              children: <Widget>[
                Icon(e.$1,
                    size: 18,
                    color: e.$4 ? Theme.of(context).colorScheme.error : VH.textSecondary),
                const SizedBox(width: VH.s3),
                Text(e.$2,
                    style: VH.label.copyWith(
                        fontSize: 13.5,
                        color: e.$4 ? Theme.of(context).colorScheme.error : VH.textPrimary)),
              ],
            ),
          ),
      ],
    );
  }
}

/// The settings, grouped and compact, at the bottom: Wi-Fi only, and the data
/// saver as one row that opens its own page.
class _SettingsGroup extends ConsumerWidget {
  const _SettingsGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final saver = ref.watch(playerSettingsProvider).get(PlayerSetting.albumDataSaver);
    return Container(
      decoration: BoxDecoration(
        color: VH.surface1,
        borderRadius: BorderRadius.circular(VH.rCard),
        border: Border.all(color: VH.hairline),
      ),
      child: Column(
        children: <Widget>[
          const _WifiOnlyRow(),
          const Divider(height: 1, thickness: 1, color: VH.hairline, indent: 48),
          InkWell(
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const DataSaverScreen())),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(VH.s3, VH.s3, VH.s2, VH.s3),
              child: Row(
                children: <Widget>[
                  Icon(Icons.data_saver_on_rounded,
                      size: 20, color: saver ? const Color(0xFF2EBD6B) : VH.textSecondary),
                  const SizedBox(width: VH.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(s.vhDataSaver, style: VH.label.copyWith(fontSize: 13.5)),
                        const SizedBox(height: 1),
                        Text(s.vhLibraryDataSaverHint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: VH.meta.copyWith(fontSize: 11)),
                      ],
                    ),
                  ),
                  if (saver)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0x292EBD6B),
                        borderRadius: BorderRadius.circular(VH.rPill),
                      ),
                      child: Text(s.vhOn,
                          style: const TextStyle(
                              color: Color(0xFF2EBD6B), fontSize: 11, fontWeight: FontWeight.w700)),
                    ),
                  const Icon(Icons.chevron_right_rounded, color: VH.textTertiary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 2:28:12, 52:10.
String _hms(int? seconds) {
  if (seconds == null || seconds <= 0) return '';
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, sec = seconds % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
