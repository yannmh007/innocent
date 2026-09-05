import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/local_browser/domain/folder.dart';
import '../../../features/local_browser/presentation/library_provider.dart';
import '../../../features/music/presentation/music_providers.dart';

/// Background media pre-warmer.
///
/// On a cold start (and especially the very first launch after install) this
/// quietly scans the videos inside every folder and writes them to
/// [LibraryCache] *before* the user opens them, so a folder opens instantly
/// instead of showing a spinner. Once the video folders are warm it primes
/// the music library too, so tapping the Music tab is instant rather than
/// kicking off a fresh scan.
///
/// ## CPU / heat safety (important)
/// Doing this work in the background is not enough on its own — a full-speed
/// background scan still pegs the CPU and heats the phone. This service is
/// deliberately *slow and flat*:
///
///  * folders are processed **one at a time** with a pause between each, so
///    the average CPU load stays low instead of spiking;
///  * work **pauses entirely while the app is backgrounded** — there is no
///    point burning battery/heat on a result the user can't see;
///  * any folder already in the cache is **skipped** (no re-scan), so repeat
///    launches are nearly free;
///  * every step is wrapped in try/catch — a pre-warm failure must never
///    crash or disrupt the foreground app.
///
/// ## Ordering
/// The folder the user just opened (passed as `priorityFolder`) is warmed
/// first. After that, folders are warmed **smallest-first**, which clears the
/// long tail of small folders quickly and cheaply and leaves the few very
/// large folders (e.g. a 1000-video camera roll) for last.
class MediaPrewarmService {
  MediaPrewarmService(this._ref);

  final Ref _ref;

  bool _running = false;
  bool _videosWarmed = false;
  String? _priority;
  final Set<String> _done = <String>{};

  /// Whether the per-folder video warm pass has finished this session.
  bool get videosWarmed => _videosWarmed;

  // Throttle knobs — tuned to favour a cool device over raw speed.
  static const Duration _folderGap = Duration(milliseconds: 220);
  static const Duration _backgroundGap = Duration(seconds: 2);
  static const Duration _musicDelay = Duration(milliseconds: 600);

  /// Begin (or keep) warming. Idempotent: calling it again while a pass is
  /// already running just records the latest [priorityFolder] and returns.
  ///
  /// [priorityFolder] is the folder the user just opened, if any — it is
  /// moved to the front of the queue.
  void start({String? priorityFolder}) {
    if (priorityFolder != null) _priority = priorityFolder;
    if (_running) return;
    _running = true;
    // Fire-and-forget. Never block a UI path on pre-warming.
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await _warmVideos();
      if (_videosWarmed) {
        await Future<void>.delayed(_musicDelay);
        await _warmMusic();
      }
    } catch (_) {
      // Best-effort: pre-warming must never surface an error to the user.
    }
  }

  Future<void> _warmVideos() async {
    final ds = _ref.read(libraryDataSourceProvider);
    final cache = _ref.read(libraryCacheProvider);

    List<Folder> folders;
    try {
      folders = await _ref.read(foldersProvider.future);
    } catch (_) {
      return; // no folder list yet → nothing to warm
    }
    if (folders.isEmpty) {
      _videosWarmed = true;
      return;
    }

    for (final path in _order(folders)) {
      if (_done.contains(path)) continue;
      await _pauseWhileBackground();
      try {
        // Skip folders already on disk — e.g. one the user already opened,
        // which the lazy loader will have cached. No wasted re-scan.
        final cached = await cache.loadVideosInFolder(path);
        if (cached == null || cached.isEmpty) {
          final vids = await ds.getVideosInFolder(path);
          await cache.saveVideosInFolder(path, vids);
        }
      } catch (_) {
        // Skip a problematic folder and keep warming the rest.
      }
      _done.add(path);
      // Breathe — let the CPU cool and keep the UI perfectly responsive.
      await Future<void>.delayed(_folderGap);
    }
    _videosWarmed = true;
  }

  /// Priority folder first, then smallest folders first.
  List<String> _order(List<Folder> folders) {
    final sorted = [...folders]
      ..sort((a, b) => a.videoCount.compareTo(b.videoCount));
    final paths = sorted.map((f) => f.path).toList();
    final p = _priority;
    if (p != null && paths.contains(p)) {
      paths.remove(p);
      paths.insert(0, p);
    }
    return paths;
  }

  Future<void> _warmMusic() async {
    try {
      // Resolving the provider in the background means the Music tab is
      // already populated the instant the user taps it. (allSongsProvider
      // does its heavy metadata work inside a `compute` isolate, so this
      // stays off the UI thread.)
      await _ref.read(allSongsProvider.future);
    } catch (_) {
      // Music warm is best-effort; the tab will scan on demand if needed.
    }
  }

  Future<void> _pauseWhileBackground() async {
    // Only `paused` is a true "backgrounded" state; `inactive` is a brief
    // transition (app switcher / notification shade) and must not stall us.
    while (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
      await Future<void>.delayed(_backgroundGap);
    }
  }
}

/// Long-lived service holder. Plain (non-autoDispose) so the warm pass keeps
/// running across tab switches.
final mediaPrewarmProvider = Provider<MediaPrewarmService>((ref) {
  return MediaPrewarmService(ref);
});
