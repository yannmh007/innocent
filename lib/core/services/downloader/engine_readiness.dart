import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloader_engine_service.dart';

/// What the engine is doing, for anything that wants to say so on screen.
enum EnginePhase {
  /// Nothing has been asked of it yet.
  idle,

  /// Unpacking itself. First run after an install.
  preparing,

  /// Fetching a newer copy.
  updating,

  /// Usable and current.
  ready,

  /// Usable but not current, or not usable at all.
  degraded,
}

/// The one place that decides when the engine gets updated.
///
/// WHY THIS EXISTS, and why the previous three attempts at it failed:
///
/// The engine bundled in the app is from November 2025 and every new install
/// reverts to it. Updating was therefore not a nicety but the difference
/// between the app working and not working — and it was scattered across a
/// screen's initState, a failure handler and a settings button, each with its
/// own idea of when it should run. Reads RACED the update instead of waiting
/// for it, which is why the same link worked when pasted a few seconds after
/// opening the screen and never worked when opened straight from a share: the
/// paste happened to arrive after the update, the share arrived before it.
///
/// So there is now one coordinator with one rule: **the engine is made current
/// before anything reads a link, and reads wait rather than race.**
///
/// It runs on four triggers, which together cover everyone:
///   1. app launch — so it is usually finished before the downloader is opened
///   2. before any read — a read waits if an update is in flight
///   3. after any failure — the most likely cause of a failure is staleness
///   4. once a week in the background, app opened or not (see the job service)
class EngineReadiness {
  EngineReadiness._();

  static final EngineReadiness instance = EngineReadiness._();

  static const String _kLastCheckKey = 'engine_last_check_v1';
  static const String _kLastFailKey = 'engine_last_fail_v1';

  /// Engines older than this are replaced immediately, schedule or not.
  ///
  /// Raise it with every release. A date beats a version comparison against
  /// "whatever we shipped with", because the bundled copy is frozen and the
  /// question is always "is this older than the app that is running it".
  static const String floor = '2026.07.01';

  /// Routine re-check interval when nothing is wrong.
  static const Duration routineInterval = Duration(days: 7);

  /// How soon a failure is allowed to trigger another check.
  static const Duration failureInterval = Duration(hours: 4);

  /// How long a read will wait for an update before going ahead regardless.
  ///
  /// There has to be a cap. An engine that cannot be updated — no network, a
  /// blocked host — must not turn into an app that refuses to try at all.
  static const Duration readWait = Duration(seconds: 40);

  /// Watchable so the UI can say "updating" instead of showing a bare spinner.
  final ValueNotifier<EnginePhase> phase =
      ValueNotifier<EnginePhase>(EnginePhase.idle);

  /// The current run, so ten callers produce one update rather than ten.
  Future<void>? _inFlight;

  EngineStatus _status = EngineStatus.unknown;
  EngineStatus get status => _status;

  bool _autoUpdateEnabled = true;

  /// Called from the app's own startup, and again whenever the setting changes.
  void configure({required bool autoUpdate}) {
    _autoUpdateEnabled = autoUpdate;
  }

  /// Kick things off at launch. Never awaited by the caller.
  void start() {
    unawaited(ensureCurrent());
    // Registering is idempotent, so doing it every launch is the simplest way
    // to be sure it is registered at all — including after an app update,
    // which clears scheduled jobs.
    unawaited(DownloaderEngineService.instance.scheduleUpdates());
  }

  /// Completes when the engine is usable and — as far as we can manage — current.
  ///
  /// Coalesced: concurrent callers share one run. Capped: it returns after
  /// [readWait] even if an update is still going, because a slow update must
  /// not become a refusal to work.
  Future<void> ensureCurrent({bool afterFailure = false}) {
    final Future<void>? running = _inFlight;
    if (running != null) return running.timeout(readWait, onTimeout: () {});
    final Future<void> run = _run(afterFailure: afterFailure);
    _inFlight = run;
    return run.whenComplete(() {
      _inFlight = null;
    }).timeout(readWait, onTimeout: () {});
  }

  /// A read or a download failed. The most common single cause is an engine
  /// that has fallen behind, so this is a trigger and not just a log line.
  Future<void> noteFailure() => ensureCurrent(afterFailure: true);

  Future<void> _run({required bool afterFailure}) async {
    try {
      phase.value = EnginePhase.preparing;
      _status = await DownloaderEngineService.instance.ensureReady();
      if (!_status.ok) {
        phase.value = EnginePhase.degraded;
        return;
      }

      if (!await _shouldUpdate(afterFailure: afterFailure)) {
        phase.value = EnginePhase.ready;
        return;
      }

      phase.value = EnginePhase.updating;
      final EngineUpdateResult result =
          await DownloaderEngineService.instance.updateEngine();
      if (result.deferred) {
        // It stood aside for a read in progress; not a check, so not recorded.
        phase.value = EnginePhase.ready;
        return;
      }
      await _mark(_kLastCheckKey);
      if (afterFailure) await _mark(_kLastFailKey);
      _status = await DownloaderEngineService.instance.ensureReady();
      phase.value = isStale ? EnginePhase.degraded : EnginePhase.ready;
    } catch (_) {
      phase.value = EnginePhase.degraded;
    }
  }

  /// True when the engine predates the app that is running it.
  bool get isStale {
    final String? version = _status.version;
    if (version == null || version.isEmpty) return true;
    return version.compareTo(floor) < 0;
  }

  Future<bool> _shouldUpdate({required bool afterFailure}) async {
    if (!_autoUpdateEnabled) return false;
    // Staleness overrides every schedule. Nothing works until it is fixed, and
    // a weekly rhythm cannot repair something broken on first launch.
    if (isStale) return true;
    if (afterFailure) {
      return _isDue(_kLastFailKey, failureInterval);
    }
    return _isDue(_kLastCheckKey, routineInterval);
  }

  Future<bool> _isDue(String key, Duration gap) async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? last = sp.getString(key);
      if (last == null) return true;
      final DateTime? at = DateTime.tryParse(last);
      if (at == null) return true;
      return DateTime.now().difference(at) > gap;
    } catch (_) {
      return false;
    }
  }

  Future<void> _mark(String key) async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(key, DateTime.now().toIso8601String());
    } catch (_) {}
  }

  /// For the diagnostics report.
  Future<String> lastCheckedLabel() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? last = sp.getString(_kLastCheckKey);
      if (last == null) return 'never';
      final DateTime? at = DateTime.tryParse(last);
      if (at == null) return 'never';
      final Duration ago = DateTime.now().difference(at);
      if (ago.inMinutes < 60) return '${ago.inMinutes}m ago';
      if (ago.inHours < 48) return '${ago.inHours}h ago';
      return '${ago.inDays}d ago';
    } catch (_) {
      return 'unknown';
    }
  }
}
