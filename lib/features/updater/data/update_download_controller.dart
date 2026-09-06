import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/connectivity/connectivity_service.dart';
import '../domain/app_release.dart';
import 'update_download_service.dart';

/// THE OWNER OF THE DOWNLOAD. One per app, never one per screen.
///
/// THE BUG THIS EXISTS TO KILL. The update screen used to hold the download
/// itself: it called the service, kept the progress in its own `setState`, and
/// died with the route. Leaving the screen and coming back built a fresh state
/// that knew nothing about the fetch still running in the foreground service,
/// so it offered a Download button — and pressing it opened a SECOND writer on
/// the same `.part`. Two appenders, one file, and a SHA-256 failure at 100%
/// that looked like a corrupt server object. Nothing about the transport was
/// wrong. There was simply no single source of truth for "is a download
/// running, and how far along is it".
///
/// So the download lives here, above the widget tree, for as long as the app
/// does. The screen observes; it does not own. [start] is idempotent: called
/// while a download for the same version is already running it ATTACHES to
/// that download and returns its future, without touching the file.
///
/// See `docs/updater_plan.md` §5.
class UpdateDownloadNotifier extends StateNotifier<UpdateDownloadState> {
  UpdateDownloadNotifier(
    this._service, {
    ConnectivityService connectivity = const ConnectivityService(),
    this.retryDelay = const Duration(seconds: 20),
  })  : _connectivity = connectivity,
        super(const UpdateDownloadState());

  final UpdateDownloadService _service;
  final ConnectivityService _connectivity;

  /// How often a stalled download re-probes the network. Injectable so the
  /// test does not wait twenty seconds to prove the loop exists.
  final Duration retryDelay;

  /// The one download. Non-null exactly while a fetch is in flight — this is
  /// the whole mutual-exclusion mechanism, and there is deliberately nothing
  /// else.
  Future<void>? _inFlight;

  /// Which release [_inFlight] is fetching.
  int? _runningVersionCode;

  /// Armed after a transient failure; disarmed on success, on a permanent
  /// failure, or on dispose.
  Timer? _reconnectTimer;

  /// Kept so auto-resume can restart the same download without the screen.
  AppRelease? _lastRelease;
  String? _lastTitle;
  String? _lastDone;

  /// Start a download, or attach to the one already running.
  ///
  /// IDEMPOTENT BY CONTRACT. Two taps on Download, a tap on Retry while the
  /// bar is still moving, and an auto-resume firing at the same moment as a
  /// tap all converge on one fetch. Only a request for a DIFFERENT version
  /// displaces a running download, because the running one is then fetching a
  /// build nobody is being offered any more.
  Future<void> start(
    AppRelease release, {
    required String notificationTitle,
    required String notificationDone,
  }) {
    final running = _inFlight;
    if (running != null) {
      if (_runningVersionCode == release.versionCode) {
        // ATTACH. Not a new fetch, not an error — the caller simply gets the
        // download that is already going, and the state stream it is already
        // publishing to.
        return running;
      }
      // A different build is being offered now. The in-flight fetch is for a
      // version this screen no longer shows, so let it finish or fail into
      // nothing while the new one takes over the state.
      _cancelReconnect();
    }

    _lastRelease = release;
    _lastTitle = notificationTitle;
    _lastDone = notificationDone;
    _runningVersionCode = release.versionCode;
    _cancelReconnect();

    final future = _run(release, notificationTitle, notificationDone);
    _inFlight = future;
    return future;
  }

  Future<void> _run(
    AppRelease release,
    String notificationTitle,
    String notificationDone,
  ) async {
    if (mounted) {
      state = UpdateDownloadState(
        versionCode: release.versionCode,
        phase: UpdateDownloadPhase.downloading,
        // Seeded from disk so a resumed download's bar starts where the last
        // one stopped instead of snapping back to zero for a few hundred ms.
        received: await _service.bytesOnDisk(release),
        total: release.apkBytes ?? 0,
      );
    }

    try {
      final file = await _service.download(
        release,
        notificationTitle: notificationTitle,
        notificationDone: notificationDone,
        onProgress: (received, total, _) {
          if (!mounted) return;
          if (state.phase != UpdateDownloadPhase.downloading) return;
          state = state.copyWith(received: received, total: total);
        },
        onVerifying: () {
          if (!mounted) return;
          state = state.copyWith(phase: UpdateDownloadPhase.verifying);
        },
      );
      if (!mounted) return;
      state = state.copyWith(
        phase: UpdateDownloadPhase.done,
        filePath: file.path,
      );
    } on UpdateDownloadFailure catch (e) {
      _finishWithFailure(release, e);
    } catch (e) {
      if (kDebugMode) debugPrint('UpdateDownloadNotifier: $e');
      _finishWithFailure(release, const UpdateDownloadFailure.io());
    } finally {
      // Cleared LAST, and only for the download that set it: an attach-then-
      // displace sequence must not let an older fetch clear a newer one's slot.
      if (_runningVersionCode == release.versionCode) {
        _inFlight = null;
      }
    }
  }

  void _finishWithFailure(AppRelease release, UpdateDownloadFailure failure) {
    if (!mounted) return;
    // The bytes are still on disk. Saying "failed" and offering Retry is
    // honest, but the download is a resume away, so the transient case arms
    // the reconnect probe rather than waiting for a tap.
    state = state.copyWith(
      phase: failure.isTransient
          ? UpdateDownloadPhase.waitingForNetwork
          : UpdateDownloadPhase.failed,
      failure: failure,
    );
    if (failure.isTransient) _armReconnect();
  }

  /// AUTO-RESUME. A tunnel, a lift, a dropped hotspot: the user should not
  /// have to know the download stopped, let alone press anything.
  ///
  /// Polling rather than a platform connectivity stream, because that is what
  /// this project already has: `ConnectivityService` does a DNS lookup and
  /// deliberately avoids `connectivity_plus`, on the grounds that an attached
  /// Wi-Fi radio is not the same as a network that reaches the internet — and
  /// for a resume, reaching the internet is the only question worth asking.
  void _armReconnect() {
    _cancelReconnect();
    _reconnectTimer = Timer.periodic(retryDelay, (_) async {
      if (!mounted) return;
      if (_inFlight != null) return; // A tap beat the timer to it.
      if (state.phase != UpdateDownloadPhase.waitingForNetwork) {
        _cancelReconnect();
        return;
      }
      if (!await _connectivity.isOnline()) return;

      final release = _lastRelease;
      final title = _lastTitle;
      final done = _lastDone;
      if (release == null || title == null || done == null) {
        _cancelReconnect();
        return;
      }
      _cancelReconnect();
      // Goes through start(), so the resume obeys the same single-owner rule
      // as a tap — including the case where the user tapped Retry in the same
      // instant this fired.
      unawaited(start(
        release,
        notificationTitle: title,
        notificationDone: done,
      ));
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Drop a finished/failed result so the screen shows a plain Download button
  /// again — used when the update check returns a different release.
  void reset() {
    if (_inFlight != null) return;
    _cancelReconnect();
    if (mounted) state = const UpdateDownloadState();
  }

  @override
  void dispose() {
    _cancelReconnect();
    super.dispose();
  }
}

/// Where the one download has got to.
@immutable
class UpdateDownloadState {
  const UpdateDownloadState({
    this.versionCode,
    this.phase = UpdateDownloadPhase.idle,
    this.received = 0,
    this.total = 0,
    this.failure,
    this.filePath,
  });

  /// Which build this state describes. The screen ignores state belonging to
  /// a version the manifest no longer offers.
  final int? versionCode;
  final UpdateDownloadPhase phase;
  final int received;
  final int total;
  final UpdateDownloadFailure? failure;
  final String? filePath;

  /// True while the download owns the `.part`. The screen must not offer a
  /// button that would call [UpdateDownloadNotifier.start] expecting a NEW
  /// fetch while this holds.
  bool get isBusy =>
      phase == UpdateDownloadPhase.downloading ||
      phase == UpdateDownloadPhase.verifying;

  double? get fraction {
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }

  /// No `clearFailure` flag, unlike the receiver's `clearError`: nothing here
  /// needs to blank a failure in place. Every start builds a whole fresh
  /// state, so a resumed download cannot inherit the sentence from the drop
  /// that stopped it.
  UpdateDownloadState copyWith({
    int? versionCode,
    UpdateDownloadPhase? phase,
    int? received,
    int? total,
    UpdateDownloadFailure? failure,
    String? filePath,
  }) {
    return UpdateDownloadState(
      versionCode: versionCode ?? this.versionCode,
      phase: phase ?? this.phase,
      received: received ?? this.received,
      total: total ?? this.total,
      failure: failure ?? this.failure,
      filePath: filePath ?? this.filePath,
    );
  }
}

enum UpdateDownloadPhase {
  idle,
  downloading,

  /// Bytes are all down; the SHA-256 is being computed.
  verifying,
  done,

  /// Stopped, the partial is intact, and the app is waiting for the network
  /// to come back so it can resume on its own.
  waitingForNetwork,

  /// Stopped for a reason that retrying by itself will not fix.
  failed,
}

final updateDownloadServiceProvider = Provider<UpdateDownloadService>(
  (ref) => const UpdateDownloadService(),
);

/// NOT `autoDispose`. The download must outlive the screen — that is the
/// entire point of this file.
final updateDownloadProvider =
    StateNotifierProvider<UpdateDownloadNotifier, UpdateDownloadState>((ref) {
  return UpdateDownloadNotifier(ref.watch(updateDownloadServiceProvider));
});
