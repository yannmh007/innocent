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
import 'playback.dart';
import 'video_hub_provider.dart';
import 'widgets/hub_states.dart';
import 'widgets/poster_image.dart';
import 'widgets/vh_insets.dart';
import '../domain/byte_size.dart';
import '../domain/video_content.dart';
import 'video_hub_theme.dart';

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
        title: Text(s.vhLibraryDownloads, style: VH.heading),
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
        error: (_, __) => HubEmptyState(message: s.vhLibraryDownloadsHint),
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
          if (items.isEmpty && pending.isEmpty) {
            return HubEmptyState(message: s.vhLibraryDownloadsHint);
          }
          // WHAT IS LEFT, not only what is taken. Somebody deciding whether
          // to download tonight's film needs the free figure more than the
          // used one, and neither was on this screen.
          final storage = ref.watch(offlineStorageProvider).valueOrNull;
          return ListView(
            padding: EdgeInsets.fromLTRB(
                VH.gutter, VH.s3, VH.gutter, VhInsets.scrollBottom(context)),
            children: <Widget>[
              if (storage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: VH.s3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(s.vhDownloadStorageLine,
                          style: VH.meta.copyWith(fontSize: 11.5)),
                      const SizedBox(height: 2),
                      Text(
                        s.vhDownloadStorage(
                          formatBytes(storage.used),
                          // A dash rather than "0 B free" when the platform
                          // did not answer: an unmeasured number presented as
                          // zero is a reason not to download that nobody
                          // actually established.
                          storage.free < 0 ? '—' : formatBytes(storage.free),
                        ),
                        style: VH.label.copyWith(fontSize: 13),
                      ),
                    ],
                  ),
                ),
              // THE ONE SETTING THIS FEATURE NEEDS, next to the thing it
              // governs rather than buried in a settings tree four screens
              // away. YouTube and Netflix both keep it in their downloads
              // section for the same reason: it is only ever thought about
              // while looking at downloads.
              const _WifiOnlyRow(),
              // WHY A DOWNLOAD STOPS WHEN THE PHONE IS PUT DOWN, in the one
              // place the person who noticed it is looking. See _BatteryRow.
              const _BatteryRow(),
              if (pending.isNotEmpty) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.only(bottom: VH.s2),
                  child: Text(s.vhDownloadUnfinished,
                      style: VH.meta.copyWith(fontSize: 12)),
                ),
                for (final p in pending) ...<Widget>[
                  _PendingRow(
                    pending: p,
                    languageCode: s.locale.languageCode,
                  ),
                  const SizedBox(height: VH.s2),
                ],
                const Divider(height: VH.s4, color: VH.surface2),
              ],
              for (var i = 0; i < items.length; i++) ...<Widget>[
                _Row(item: items[i], languageCode: s.locale.languageCode),
                if (i != items.length - 1) const SizedBox(height: VH.s2),
              ],
            ],
          );
        },
      ),
    );
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
    return InkWell(
      onTap: () => _play(context, ref),
      borderRadius: BorderRadius.circular(VH.rControl),
      child: Padding(
        padding: const EdgeInsets.all(VH.s2),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 76,
              height: 56,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: PosterImage(
                  mediaRef: item.posterUrl == null
                      ? MediaRef.none
                      : MediaRef(provider: 'url', locator: item.posterUrl!),
                  title: _shownTitle,
                ),
              ),
            ),
            const SizedBox(width: VH.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(_shownTitle,
                      style: VH.label.copyWith(fontSize: 14.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Text(formatBytes(item.bytes),
                      style: VH.meta.copyWith(fontSize: 12)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: VH.textTertiary),
              onPressed: () => _confirmDelete(context, ref),
            ),
          ],
        ),
      ),
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
    await ref.read(offlineLibraryProvider).drop(item.titleId);
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
    final live = ref.read(offlineDownloaderProvider).watch(item.titleId);
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
        titleId: item.titleId,
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
            source: content.source,
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
    ref.read(offlineDownloaderProvider).cancel(item.titleId);
    await ref.read(offlineLibraryProvider).discardPending(item.titleId);
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

    return Padding(
      padding: const EdgeInsets.all(VH.s2),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 76,
            height: 56,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: PosterImage(
                mediaRef: item.posterUrl == null
                    ? MediaRef.none
                    : MediaRef(provider: 'url', locator: item.posterUrl!),
                title: _shownTitle,
              ),
            ),
          ),
          const SizedBox(width: VH.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(_shownTitle,
                    style: VH.label.copyWith(fontSize: 14.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                // THE BYTES ALREADY PAID FOR, on screen. Somebody deciding
                // whether to carry on needs to know they are 700 MB into a
                // 900 MB film and not starting again — that is the whole
                // difference between resuming and giving up.
                Text(
                  _line(s, live: live, received: received, total: total),
                  style: VH.meta.copyWith(fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 3,
                    backgroundColor: VH.surface2,
                  ),
                ),
              ],
            ),
          ),
          // WATCH IT WHILE IT ARRIVES. Offered from about eight megabytes in,
          // which on this connection is a minute or two — and only when the
          // film's length is known, because without it there is no seek bar to
          // draw. Whether it can ACTUALLY start is read out of the file when
          // this is tapped rather than on every rebuild: the answer needs a
          // read and a decrypt, and a list does not get to do that per frame.
          if (total != null && received >= _watchFrom)
            IconButton(
              icon: _opening
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_circle_outline,
                      color: VH.textSecondary),
              tooltip: s.vhWatchNow,
              onPressed: _opening ? null : () => _watchNow(total),
            ),
          if (running)
            TextButton(
              onPressed: () =>
                  ref.read(offlineDownloaderProvider).cancel(item.titleId),
              child: Text(s.vhDownloadPause, style: VH.meta.copyWith(fontSize: 12)),
            )
          else
            IconButton(
              icon: _starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow_rounded,
                      color: VH.textSecondary),
              tooltip: s.vhDownloadResume,
              onPressed: _starting ? null : _resume,
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: VH.textTertiary),
            onPressed: _discard,
          ),
        ],
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
      padding: const EdgeInsets.only(bottom: VH.s3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(s.vhDownloadWifiOnly,
                    style: VH.label.copyWith(fontSize: 13.5)),
                const SizedBox(height: 2),
                // THE HINT SAYS WHY IT IS OFF. A switch whose default looks
                // wrong invites somebody to "fix" it, and turning this on is
                // exactly the wrong move for a viewer with no wifi — their
                // downloads would then wait for something that never comes.
                Text(s.vhDownloadWifiOnlyHint,
                    style: VH.meta.copyWith(fontSize: 11.5)),
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
