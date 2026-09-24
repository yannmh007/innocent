import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/services/video_player/disk_cache_dir.dart';
import 'core/router/app_router.dart';
import 'core/router/routes.dart';
import 'core/services/diagnostics/crash_breadcrumbs.dart';
import 'core/services/diagnostics/crash_diagnostics.dart';
import 'core/services/diagnostics/sentry_reporting.dart';
import 'core/services/equalizer/equalizer_service.dart';
import 'core/services/music_background/music_audio_handler.dart';
import 'core/services/preferences/settings_migration_service.dart';
import 'core/services/user_data/user_data_service.dart';
import 'core/services/video_player/media_kit_player_service.dart';
import 'features/music/data/music_audio_service.dart';
import 'features/music/presentation/music_providers.dart';
import 'features/onboarding/onboarding_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // v1.61 — FIRST, before anything that can fail.
  //
  // The app has been dying outright during playback and there was no way to
  // see why from a phone. `start()` rotates the previous run's breadcrumb
  // file so it survives to be read, and installs itself as PlaybackLog's
  // sink; the error hook records anything Dart throws. Neither can see a
  // NATIVE crash — for that, the reason the previous process ended is read
  // back from Android in Settings → Diagnostics.
  await CrashBreadcrumbs.start();
  CrashDiagnostics.installErrorHooks();

  // Anything the streaming disk cache left behind. It should be nothing —
  // the files are unlinked the moment they are created, so even a crash
  // takes them with it — and that is exactly why this runs unawaited and
  // never blocks the start-up path. What it catches is the platform's
  // exceptions to "should be nothing", where a stray gigabyte would
  // otherwise sit on a viewer's phone with no name and no owner.
  unawaited(DiskCacheDir.sweep());

  // Audit: cap the image cache before any widget is built so a large
  // library with hundreds of thumbnails can't blow past memory. Flutter
  // defaults are 1000 images / 100 MB; for a heavy media app with many
  // 480p thumbnails we tighten the byte cap and slightly lift the
  // count to fit a typical scroll-page worth without thrashing.
  PaintingBinding.instance.imageCache
    ..maximumSize = 200
    ..maximumSizeBytes = 64 * 1024 * 1024; // 64 MB

  // Audit: run any pending settings migrations once at cold start, so
  // a user upgrading from a build that predated a key rename doesn't
  // silently lose their preferences. Scaffolding only at v1 — no
  // concrete migrations exist yet but the ladder is in place for
  // future enum renames.
  try {
    await SettingsMigrationService.runMigrations();
  } catch (e) {
    // Migration failure should never block app startup; the user just
    // falls back to whatever values SharedPreferences already has.
    if (kDebugMode) debugPrint('Settings migration failed: $e');
  }

  // Phase 45 (audit): friendly error widget. Flutter's default "red
  // error screen" is fine for development but terrifying for users.
  // In release we show a small dark card with an apology. The error
  // is still logged to the console for debugging.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    // Always surface *what* failed (exception + stack) to the log, even in
    // release, so an intermittent build crash can be traced from logcat
    // instead of only showing the generic card to the user.
    debugPrint('ErrorWidget caught: ${details.exception}\n${details.stack}');
    // Keep the newest failure so the card can show it on demand. Without a
    // connected debugger this is the only way to learn what actually broke,
    // and these failures are intermittent — a screenshot of the card is the
    // whole bug report.
    lastBuildFailure = details;
    CrashBreadcrumbs.addError('build', details.exception, details.stack);
    return _RecoverableErrorCard(details: details);
  };

  // v0.94: swallow-and-log errors thrown from async work that nothing awaited
  // — a failed transfer chunk, a scan that raced a disconnect, a plugin
  // callback firing after a screen closed. Without a handler these become
  // unhandled zone errors, which on Android can tear the isolate down and
  // leave the app looking frozen until it's killed from recents. Logging and
  // returning true keeps the app alive; anything that genuinely needs to
  // surface to the user is already reported through its own UI.
  PlatformDispatcher.instance.onError = (error, stack) {
    // v1.61: also written to the persistent trail. `debugPrint` alone is
    // invisible in a release build on a phone, which is the only place this
    // app runs.
    CrashBreadcrumbs.addError('uncaught async', error, stack);
    debugPrint('Uncaught async error: $error\n$stack');
    return true;
  };

  // AFTER the two hooks above, and the order is the whole point.
  //
  // Sentry's OnErrorIntegration captures whatever `PlatformDispatcher.onError`
  // already holds and calls it, returning its result — so the `return true`
  // decided just above survives, and an unawaited failure still keeps the
  // isolate alive. Start it BEFORE that assignment and the assignment wins:
  // Sentry's handler is overwritten and no async error is ever reported.
  //
  // Does nothing at all unless the build carries
  // `--dart-define=SENTRY_DSN=…`, which CI's does not. See
  // lib/core/services/diagnostics/sentry_reporting.dart.
  await SentryReporting.start();

  // Phase 45: tune the Flutter image cache for the realistic devices
  // people install MX-clones on. Default Flutter caps live image cache
  // at ~100 MB which on a phone with 2 GB total RAM forces the engine
  // to evict cached thumbnails frequently, causing the visible
  // "thumbnails redraw on scroll" flicker. We cap at 80 MB / 200
  // entries — small enough to leave room for libmpv's frame buffers,
  // large enough to keep typical scroll fluid.
  PaintingBinding.instance.imageCache
    ..maximumSize = 200
    ..maximumSizeBytes = 80 * 1024 * 1024;

  // Initialize media_kit native libs
  MediaKit.ensureInitialized();

  // Wire the equalizer's audio-session id to the video player. The player
  // asks this hook (at each video's startup) for the shared session id and
  // binds libmpv's AudioTrack output to it, so the native Equalizer /
  // BassBoost / Virtualizer effects actually process the video's sound
  // instead of sitting on the global mix (which modern Android ignores).
  // A single shared EqualizerService instance is reused for the hook and by
  // the UI provider (see equalizerServiceProvider) so ids and state match.
  EqualizerSessionBinder.sessionIdProvider =
      () => sharedEqualizerService.ensureSessionId();

  // Audit fix (real gap: music background play): boot the
  // audio_service foreground service BEFORE runApp so OS hosts us
  // as a media-playback foreground service. Shared MusicAudioService
  // is built here so both handler + Riverpod provider reference the
  // same instance — otherwise taps in app vs taps on lock-screen
  // notification would drive two different players. Init is
  // best-effort: on web (not supported) the catch leaves
  // audioHandler null and music degrades to foreground-only.
  final sharedMusicAudio = MusicAudioService();
  MusicAudioHandler? audioHandler;
  try {
    audioHandler = await AudioService.init(
      builder: () => MusicAudioHandler(sharedMusicAudio),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.innocent.media.audio',
        androidNotificationChannelName: 'Innocent Music',
        androidNotificationChannelDescription:
            'Playback controls for the Music tab',
        // Build fix (audio_service 0.18.18 const assertion): when the
        // notification is `ongoing` (not swipe-dismissable while playing),
        // audio_service requires androidStopForegroundOnPause: true so the
        // service leaves foreground state on pause — otherwise the
        // notification could become permanently undismissable. This is the
        // standard music-player pairing: locked while playing, dismissable
        // when paused.
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        // Audit fix: was 'mipmap/ic_launcher', which this project does
        // not ship (no mipmap resource exists) -> notification icon
        // failed to resolve and music controls never showed. Points at
        // the bundled monochrome music-note drawable instead.
        androidNotificationIcon: 'drawable/ic_stat_music',
      ),
    );
    AudioServiceStatus.ok = true;
    CrashBreadcrumbs.add('AudioService.init ok');
  } catch (e, st) {
    // v1.61 — THIS CATCH USED TO HIDE THE WHOLE PROBLEM.
    //
    // The only report was a debugPrint behind `kDebugMode`, which is false in
    // a release build, so a failing init was completely invisible: no music
    // notification, no lock-screen controls, dead home-screen widget buttons
    // and no foreground service of its own — with nothing anywhere saying
    // why. The failure is now recorded where it can be read from the phone
    // (Settings → Diagnostics).
    AudioServiceStatus.ok = false;
    AudioServiceStatus.error = e.toString();
    CrashBreadcrumbs.addError('AudioService.init', e, st);
    if (kDebugMode) debugPrint('AudioService init failed (background music disabled): $e');
  }

  // Edge-to-edge UI
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Phase 45 (audit): make system bars (status + navigation) fully
  // transparent so the app's dark background extends behind them.
  // Without this, Android 12+ shows a translucent gray scrim that
  // looks like a "second app bar" — confusing on edge-to-edge UIs.
  // Light icons because our app is dark-theme.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0x00000000),
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Color(0x00000000),
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Color(0x00000000),
  ));
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Phase 10: Auto-cleanup recycle bin entries older than 30 days
  // Runs in background, doesn't block startup
  // ignore: discarded_futures
  () async {
    try {
      await UserDataService().cleanupOldRecycleBinEntries();
    } catch (e) { if (kDebugMode) debugPrint('main.best-effort: $e'); }
  }();

  // Check onboarding status
  final showOnboarding = await OnboardingScreen.shouldShow();

  runApp(
    ProviderScope(
      overrides: [
        // Share single MusicAudioService between foreground notifier
        // + background AudioService handler.
        musicAudioServiceProvider.overrideWithValue(sharedMusicAudio),
        // Expose handler so MusicPlayingNotifier can wire its
        // callbacks. Null is acceptable — notifier no-ops handler
        // hookups when null (no background controls, foreground
        // music still works).
        musicAudioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: InnocentApp(showOnboarding: showOnboarding),
    ),
  );
}

/// Replaces a subtree whose build threw. Unlike a static card, it offers a way
/// out — "Go back" pops the errored route (or resets to Home) so a transient
/// build failure (e.g. flipping a picker category before its data arrived)
/// can't leave the app permanently stuck, forcing a kill-from-recents.
/// The most recent build failure, kept so the error card (and a future
/// bug-report action) can show what actually went wrong.
FlutterErrorDetails? lastBuildFailure;

class _RecoverableErrorCard extends StatefulWidget {
  const _RecoverableErrorCard({this.details});

  final FlutterErrorDetails? details;

  @override
  State<_RecoverableErrorCard> createState() => _RecoverableErrorCardState();
}

class _RecoverableErrorCardState extends State<_RecoverableErrorCard> {
  bool _showDetails = false;

  /// A short, readable description of the failure — the exception line plus
  /// the first few stack frames from our own code, which is what identifies
  /// the culprit. Framework frames are dropped: they're the same for every
  /// crash and just push the useful lines off screen.
  String get _diagnostic {
    final d = widget.details ?? lastBuildFailure;
    if (d == null) return 'No details captured.';
    final buf = StringBuffer()..writeln(d.exception.toString());
    final stack = d.stack?.toString() ?? '';
    final lines =
        stack.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
    // Show our own frames first (they pinpoint the exact file+line). If the
    // build stripped package paths, fall back to the first several raw frames
    // — still enough to locate the failure — and if there's no stack at all,
    // fall back to the widget/library Flutter recorded.
    final ours = lines.where((l) => l.contains('innocent/')).take(8).toList();
    final show = ours.isNotEmpty ? ours : lines.take(10).toList();
    if (show.isEmpty) {
      final ctx = d.context?.toString();
      final lib = d.library;
      if (lib != null) buf.writeln('(in: $lib)');
      if (ctx != null && ctx.isNotEmpty) buf.writeln(ctx);
      buf.writeln('(no stack trace in this build)');
    } else {
      for (final l in show) {
        buf.writeln(l);
      }
    }
    return buf.toString().trim();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF121212),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: Color(0xFFFFA000), size: 48),
            const SizedBox(height: 12),
            const Text(
              "Something didn't load",
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'This screen hit a snag.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: () {
                    final nav = rootNavigatorKey.currentState;
                    if (nav != null && nav.canPop()) {
                      nav.pop();
                    } else {
                      nav?.popUntil((r) => r.isFirst);
                    }
                  },
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('Go back'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF2196F3),
                  ),
                ),
                const SizedBox(width: 8),
                // A plain pop can't help when the failing subtree IS the screen
                // you're on — that's what left the app looking dead until it was
                // killed from recents. Reload rebuilds the whole stack from the
                // home route, which clears a transient build failure in place.
                TextButton.icon(
                  onPressed: () {
                    final ctx = rootNavigatorKey.currentContext;
                    if (ctx == null) return;
                    try {
                      GoRouter.of(ctx).go(Routes.local);
                    } catch (e) {
                      debugPrint('Reload from error card failed: $e');
                      rootNavigatorKey.currentState
                          ?.popUntil((r) => r.isFirst);
                    }
                  },
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Reload'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF2196F3),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // The exception itself, behind a tap. These failures are
            // intermittent and hard to reproduce, so letting the user read (and
            // screenshot) the actual error turns a vague "it broke again" into
            // an exact fix.
            TextButton(
              onPressed: () => setState(() => _showDetails = !_showDetails),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white38,
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: Text(_showDetails ? 'Hide details' : 'Details'),
            ),
            if (_showDetails)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(
                      _diagnostic,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10.5,
                        height: 1.45,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: _diagnostic));
                          final m = ScaffoldMessenger.maybeOf(context);
                          m?.showSnackBar(const SnackBar(
                            content: Text('Error details copied'),
                            duration: Duration(seconds: 2),
                          ));
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy'),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF2196F3),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
