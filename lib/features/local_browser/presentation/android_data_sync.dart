import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/adb/adb_service.dart';
import 'library_provider.dart';

/// ANDROID/DATA'S VIDEOS ARE IN THE VIDEO TAB AS SOON AS ADB IS UP, WHEREVER
/// IT WAS CONNECTED.
///
/// The scan that finds them used to run in three places only: at app start
/// (when already connected), on pull-to-refresh, and right after connecting
/// on the ADB screen. Connecting from Me → Hidden files, or switching
/// Wireless debugging back on while the "connection lost" card waited, left
/// the Video tab showing whatever the last scan had found — for a first
/// connection, nothing at all.
///
/// Now a connection made anywhere is noticed ([AdbService.live] turning
/// true) and followed by a scan, and so is coming back to the app with the
/// connection up. One scan at a time, and not again within [fresh] (or
/// [resumeEvery] for a return to the app): a `find` across every app's
/// folder is several seconds of the phone's work.
///
/// And not while somebody is using the connection ([soon]). The ADB engine
/// runs one command at a time; a scan started the moment Hidden files
/// connected would hold up the next folder opened there for as long as it
/// ran. It waits for [quiet] — a pause in browsing — instead. (Streaming
/// and pictures do not wait on commands, so a film playing is not one.)
class AndroidDataSync with WidgetsBindingObserver {
  AndroidDataSync({
    required void Function() onScanned,
    Future<bool> Function()? everConnected,
    Future<bool> Function()? probe,
    Future<List<String>> Function()? scan,
    ValueListenable<bool?>? live,
    DateTime Function()? now,
    Duration Function()? idleFor,
    Duration tick = const Duration(seconds: 1),
  })  : _onScanned = onScanned,
        _idleFor = idleFor ?? (() => AdbService.instance.idleFor),
        _tick = tick,
        _everConnected = everConnected ??
            (() async =>
                (await AdbService.instance.lastConnect()).isNotEmpty),
        _probe = probe ??
            (() => AdbService.instance.isConnected(timeoutMs: 3000)),
        _scan = scan ?? AdbService.instance.scanAndroidDataVideos,
        _live = live ?? AdbService.instance.live,
        _now = now ?? DateTime.now;

  /// No second scan this soon after one, however the connection came up.
  static const Duration fresh = Duration(minutes: 2);

  /// No scan on a return to the app this soon after the last one.
  static const Duration resumeEvery = Duration(minutes: 10);

  /// How long the connection must have carried no command before a
  /// background scan takes it.
  static const Duration quiet = Duration(seconds: 8);

  final void Function() _onScanned;
  final Future<bool> Function() _everConnected;
  final Future<bool> Function() _probe;
  final Future<List<String>> Function() _scan;
  final ValueListenable<bool?> _live;
  final DateTime Function() _now;
  final Duration Function() _idleFor;
  final Duration _tick;

  Future<List<String>?>? _running;
  Timer? _waiting;
  bool _waitConnected = false;
  DateTime? _lastScan;
  List<String>? _lastFound;
  bool? _wasLive;
  bool _started = false;

  /// What the last scan found (paths), or null before one has finished.
  List<String>? get lastFound => _lastFound;

  /// Watch the connection and the app's comings and goings, and scan now if
  /// ADB is already up.
  void start({bool observeLifecycle = true}) {
    if (_started) return;
    _started = true;
    _wasLive = _live.value;
    _live.addListener(_onLive);
    if (observeLifecycle) WidgetsBinding.instance.addObserver(this);
    unawaited(sync());
  }

  void dispose() {
    _waiting?.cancel();
    _waiting = null;
    if (!_started) return;
    _live.removeListener(_onLive);
    WidgetsBinding.instance.removeObserver(this);
  }

  void _onLive() {
    final now = _live.value;
    final was = _wasLive;
    _wasLive = now;
    // Up after down (or after not knowing): something just connected.
    if (now == true && was != true) soon(connected: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final last = _lastScan;
    if (last != null && _now().difference(last) < resumeEvery) return;
    soon();
  }

  /// [sync], once the connection has been [quiet]: for scans nobody asked
  /// for, which must not hold up somebody's browsing.
  void soon({bool connected = false}) {
    final last = _lastScan;
    if (last != null && _now().difference(last) < fresh) return;
    _waitConnected = _waitConnected || connected;
    if (_waiting != null) return;
    _waiting = Timer.periodic(_tick, (_) {
      if (_idleFor() < quiet) return;
      _waiting?.cancel();
      _waiting = null;
      final c = _waitConnected;
      _waitConnected = false;
      unawaited(sync(connected: c));
    });
  }

  /// Whether a background scan is waiting for a pause.
  @visibleForTesting
  bool get waiting => _waiting != null;

  /// Scan Android/data for videos and refresh the Video tab with them.
  ///
  /// [connected]: the caller has just used the connection, so there is no
  /// need to ask whether it is up. [force]: scan even within [fresh] (the
  /// ADB screen's Scan button). Returns the paths found, the last scan's
  /// when this one was skipped as too soon, or null when there was no
  /// connection or the scan failed. Never throws.
  Future<List<String>?> sync({bool connected = false, bool force = false}) {
    final running = _running;
    if (running != null) {
      if (!connected) return running;
      // The one running may be a probe that started before this connection
      // came up, and will answer "not connected": once it is done, a
      // connection that has just been used is scanned after all. (The test
      // that found this: Hidden files opened during the start-up probe.)
      return running.then((found) => found ?? sync(connected: true));
    }
    final last = _lastScan;
    if (!force && last != null && _now().difference(last) < fresh) {
      return Future<List<String>?>.value(_lastFound);
    }
    final f = _sync(connected);
    _running = f;
    return f.whenComplete(() {
      if (identical(_running, f)) _running = null;
    });
  }

  Future<List<String>?> _sync(bool connected) async {
    try {
      if (!connected) {
        // Nobody who has never connected is asked: there is nothing to wake.
        if (!await _everConnected()) return null;
        if (!await _probe()) return null;
      }
      // Stamped before the scan, so a failing one is not retried at once by
      // the next command that happens to succeed.
      _lastScan = _now();
      final found = await _scan();
      _lastFound = found;
      _onScanned();
      return found;
    } catch (e) {
      if (kDebugMode) debugPrint('AndroidDataSync: $e');
      return null;
    }
  }
}

/// Bumped after every Android/data scan, for anything that shows what it
/// found and keeps its own copy.
final androidDataScanEpochProvider = StateProvider<int>((_) => 0);

/// Kept alive for the whole app session by a watch in the shell.
final androidDataSyncProvider = Provider<AndroidDataSync>((ref) {
  final sync = AndroidDataSync(onScanned: () {
    // The scan saved what it found (an empty result too: the files are
    // gone), so the Video tab reads it again.
    ref.invalidate(adbVideosProvider);
    ref.read(androidDataScanEpochProvider.notifier).state++;
  });
  ref.onDispose(sync.dispose);
  sync.start();
  return sync;
});
