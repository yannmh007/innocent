import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../data/api/event_sender.dart';
import '../../data/api/offline_downloader.dart';
import '../../data/device_identity.dart';
import '../../domain/video_content.dart';
import '../account_provider.dart';
import '../video_hub_provider.dart';
import '../video_hub_theme.dart';

/// Download / downloading / downloaded, in one control.
///
/// THREE STATES AND ONE BUTTON, because they are one decision to the person
/// looking at it: "is this on my phone". Splitting them across a button, a
/// progress bar and a badge would mean three things to find on a screen whose
/// job is to show artwork.
///
/// HIDDEN ENTIRELY FOR A VIEWER WHO CANNOT DOWNLOAD. Not disabled, not
/// upgrade-prompted: the Play button already carries the paywall for this
/// title, and a second locked control beside it teaches nothing and takes
/// room. [AccessPolicy.canDownload] decides, which is the same table the rest
/// of the feature asks.
class DownloadAction extends ConsumerStatefulWidget {
  final VideoContent content;

  const DownloadAction({super.key, required this.content});

  @override
  ConsumerState<DownloadAction> createState() => _DownloadActionState();
}

class _DownloadActionState extends ConsumerState<DownloadAction> {
  StreamSubscription<OfflineProgress>? _sub;
  OfflineProgress? _progress;
  bool _onDisk = false;
  bool _checked = false;

  VideoContent get content => widget.content;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Re-attaches to a download this screen did not start — the user can back
    // out of the detail screen and come back while it runs, and a control
    // that forgot would offer to start a second writer on the same file.
    final live = ref.read(offlineDownloaderProvider).watch(content.id);
    if (live != null) _listen(live);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final has = await ref.read(offlineLibraryProvider).has(content.id);
    if (!mounted) return;
    setState(() {
      _onDisk = has;
      _checked = true;
    });
  }

  void _listen(Stream<OfflineProgress> stream) {
    _sub?.cancel();
    _sub = stream.listen((p) {
      if (!mounted) return;
      setState(() => _progress = p);
    }, onDone: () {
      if (!mounted) return;
      setState(() => _progress = null);
      _refresh();
      ref.invalidate(offlineItemsProvider);
    });
  }

  Future<void> _start() async {
    final s = AppStrings.of(context);
    logEvent(ref, Ev.downloadStart, titleId: content.id);

    final downloader = ref.read(offlineDownloaderProvider);
    final deviceId = await DeviceIdentity.get();
    if (!mounted) return;

    // NO `watch` HERE ANY MORE. Asking for the stream before `download` is
    // called asks for a stream that does not exist yet — `download` is what
    // creates it — so the answer was always null and the download this button
    // had just started reported nothing at all. For an hour. The only way to
    // see progress was to leave the screen and come back, which re-attached
    // through `watch` and worked, which is why it was never noticed.
    //
    // The reason a download stops is KEPT OUTSIDE THE WIDGET'S STATE. It is
    // the last thing reported, and clearing the state field is exactly what
    // has to happen before the control can be drawn again — so reading the
    // reason back off that field afterwards reads null every time.
    String? failure;
    final item = await downloader.download(
      content: content,
      source: content.source,
      deviceId: deviceId,
      // The notification is the only part of an hour-long download the viewer
      // sees, so it is in their language and not in the downloader's.
      notices: DownloadNotices(
        waiting: s.vhDownloadWaitingSignal,
        ready: s.vhDownloadReadyOffline,
      ),
      onProgress: (p) {
        if (p.error != null) failure = p.error;
        if (!mounted) return;
        setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    setState(() => _progress = null);

    if (item != null) {
      // Only on success. A download_complete written for a transfer that gave
      // up would make the funnel say people are keeping titles they never
      // got, which is worse than recording nothing.
      logEvent(ref, Ev.downloadComplete, titleId: content.id);
      await _refresh();
      ref.invalidate(offlineItemsProvider);
      ref.invalidate(offlinePendingProvider);
      return;
    }
    if (!mounted) return;
    // Whatever is on disk is now an unfinished download the Downloads screen
    // can offer to resume, so that list has changed too.
    ref.invalidate(offlinePendingProvider);
    // WHICH FAILURE IT WAS, because they are not the same problem and only one
    // of them is the viewer's to fix. A full phone is a thing they can act on
    // in a minute; an entitlement refusal is not; a connection that never came
    // back is neither. One sentence for all three sent everybody to the wrong
    // place — and on a metered connection, to spend the data again.
    final failed = failure;
    // A CANCELLATION IS NOT A FAILURE. The viewer pressed Cancel; telling them
    // afterwards that the title is unavailable contradicts what they just did
    // and invites them to think something broke.
    if (failed == null) return;
    final message = failed == 'no_space'
        ? s.vhDownloadNoSpace
        : failed == 'gave_up'
            ? s.vhDownloadGaveUp
            : s.vhUnavailable;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _remove() async {
    await ref.read(offlineLibraryProvider).drop(content.id);
    if (!mounted) return;
    ref.invalidate(offlineItemsProvider);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final policy = ref.watch(accessPolicyProvider);
    final tier = ref.watch(viewerProvider).tier;
    if (!policy.canDownload(content, tier)) return const SizedBox.shrink();

    // Nothing at all until the shelf has been read. One frame of "Download"
    // on a title that is already downloaded would invite a tap that starts a
    // second copy.
    if (!_checked) return const SizedBox(height: 36);

    final running = _progress;
    if (running != null && !running.done && running.error == null) {
      final f = running.fraction;
      if (running.queued) {
        // Waiting its turn behind another download. Said out loud, or the
        // viewer taps again and wonders why nothing happens.
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.schedule_rounded,
                size: 16, color: VH.textTertiary),
            const SizedBox(width: VH.s2),
            Text(s.vhDownloadQueued, style: VH.meta.copyWith(fontSize: 12)),
            TextButton(
              onPressed: () =>
                  ref.read(offlineDownloaderProvider).cancel(content.id),
              child: Text(s.cancel, style: VH.meta.copyWith(fontSize: 12)),
            ),
          ],
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 18,
            height: 18,
            // Indeterminate while the size is unknown — a bar pinned at zero
            // for the first minute of a download that IS running reads as a
            // stall.
            child: CircularProgressIndicator(
              value: f,
              strokeWidth: 2,
              color: VH.textSecondary,
            ),
          ),
          const SizedBox(width: VH.s2),
          Text(
            f == null ? '…' : '${(f * 100).round()}%',
            style: VH.meta.copyWith(fontSize: 12),
          ),
          TextButton(
            onPressed: () =>
                ref.read(offlineDownloaderProvider).cancel(content.id),
            child: Text(s.cancel, style: VH.meta.copyWith(fontSize: 12)),
          ),
        ],
      );
    }

    if (_onDisk) {
      return TextButton.icon(
        onPressed: _remove,
        icon: const Icon(Icons.download_done_rounded,
            size: 18, color: VH.textSecondary),
        label: Text(s.delete, style: VH.meta.copyWith(fontSize: 12.5)),
      );
    }

    return TextButton.icon(
      onPressed: _start,
      icon: const Icon(Icons.download_outlined,
          size: 18, color: VH.textSecondary),
      label: Text(s.vhLibraryDownloads, style: VH.meta.copyWith(fontSize: 12.5)),
    );
  }
}
