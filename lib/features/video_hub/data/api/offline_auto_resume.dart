import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/connectivity/connectivity_service.dart';
import '../../presentation/video_hub_provider.dart';
import '../device_identity.dart';
import 'offline_downloader.dart';

/// Picks up downloads that were interrupted, without being asked.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS IS THE FEATURE AND NOT A CONVENIENCE
/// ═══════════════════════════════════════════════════════════════════════
///
/// On a Myanmar mobile connection a film takes an hour or two, and being
/// interrupted is the ordinary case rather than the unusual one: the signal
/// goes, the phone is closed, Android reclaims the app. Until now every one of
/// those left a part file and a row, and the viewer had to notice, open
/// Downloads, and press Resume — for something they had already asked for and
/// already paid the data for. Netflix, YouTube, Chrome and Telegram all simply
/// carry on. Not carrying on is the difference between "I left it downloading
/// overnight" ending in a finished film and ending in a shrug.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT IT WILL NOT DO
/// ═══════════════════════════════════════════════════════════════════════
///
/// Resume something the VIEWER paused. That is the whole line, and it is the
/// only one that can be drawn honestly — "interrupted" and "paused" look
/// identical on disk, so the pause is recorded when it happens (see
/// [PendingDownload.pausedByUser]). Resuming a deliberate pause would be the
/// app overruling somebody and spending their data to do it.
///
/// It also will not spend a connection it is not allowed to: the downloader's
/// own allowance check refuses a metered link when "Wi-Fi only" is on, and it
/// refuses before asking the server for anything, so a wrong moment costs
/// nothing at all.
class OfflineAutoResume {
  const OfflineAutoResume._();

  /// The shortest gap between two sweeps.
  ///
  /// The app can be resumed many times in a minute — a notification pulled
  /// down, a call taken, a glance at the clock — and each one is a chance to
  /// re-read the shelf and issue a round of `requestPlayback` calls. Two
  /// minutes is short enough that walking into wifi is noticed on the next
  /// glance at the phone, and long enough that the sweep is never the reason
  /// anything feels slow.
  static const Duration minimumGap = Duration(minutes: 2);

  static DateTime? _lastRun;
  static bool _running = false;

  /// Exposed for tests, which must not inherit a previous case's clock.
  @visibleForTesting
  static void resetForTest() {
    _lastRun = null;
    _running = false;
  }

  /// Resume everything that was interrupted, if anything was.
  ///
  /// [notices] carries the notification wording, because this runs from a
  /// screen that HAS a locale and the downloader does not — a resumed download
  /// must not be the one that speaks English at somebody.
  ///
  /// Never throws. A sweep that cannot run is a download that waits for the
  /// next one, which is the state the app was in before this existed.
  /// [ref] is a [WidgetRef] because the only caller is a screen — the one
  /// thing in the app that both survives the whole session and knows the
  /// viewer's language. A provider could hold this instead and would then have
  /// no locale to give the notification.
  static Future<void> maybeRun(
    WidgetRef ref, {
    required DownloadNotices notices,
  }) async {
    if (_running) return;
    final last = _lastRun;
    if (last != null && DateTime.now().difference(last) < minimumGap) return;
    _running = true;
    _lastRun = DateTime.now();
    try {
      final library = ref.read(offlineLibraryProvider);
      final downloader = ref.read(offlineDownloaderProvider);

      // CHEAPEST QUESTION FIRST. Reading the shelf is two preference reads and
      // a directory stat; the online probe is a DNS round trip. Most launches
      // have nothing to resume, and those must cost nothing.
      final pending = await library.pending();
      final due = <String>[];
      for (final p in pending) {
        if (p.item.pausedByUser) continue;
        if (downloader.isRunning(p.item.titleId)) continue;
        due.add(p.item.titleId);
      }
      if (due.isEmpty) return;

      if (!await const ConnectivityService().isOnline()) return;

      final repo = ref.read(contentRepositoryProvider);
      final deviceId = await DeviceIdentity.get();
      for (final titleId in due) {
        // THE TITLE IS FETCHED RATHER THAN STORED. The pending row carries
        // enough to DRAW itself with no network, which is what an offline
        // screen needs; resuming is a network operation by definition, so this
        // costs nothing that was not already being spent — and a whole
        // catalogue record copied onto disk would be a stale one for ever.
        final content = await repo.getById(titleId);
        if (content == null) continue;
        // NOT AWAITED. The downloader queues these internally and runs them
        // one at a time; awaiting here would hold this sweep open for the two
        // hours the first film takes, and the second would never be asked for.
        // ignore: discarded_futures
        downloader.download(
          content: content,
          source: content.source,
          deviceId: deviceId,
          notices: notices,
          // NO SIZE QUESTION ON A RESUME. It was asked and answered when the
          // download started; asking again would be the app forgetting what it
          // was told, every time the phone was unlocked.
        );
      }
      ref.invalidate(offlinePendingProvider);
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineAutoResume: $e');
    } finally {
      _running = false;
    }
  }
}
