import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/ui/tv_focus.dart';
import 'core/services/preferences/extra_settings_service.dart';
import 'core/services/preferences/player_settings_service.dart';
import 'core/services/thumbnail/thumbnail_cache.dart';
import 'features/network/data/net_repository.dart';
import 'features/local_browser/data/library_local_datasource.dart';

import 'core/di/core_providers.dart';
import 'core/di/preferences_provider.dart';
import 'core/localization/app_strings.dart';
import 'core/localization/locale_provider.dart';
import 'core/router/app_router.dart';
import 'core/router/routes.dart';
import 'core/services/downloader/engine_readiness.dart';
import 'core/services/external_intent/external_intent_service.dart';
import 'core/services/preferences/preferences_service.dart';
import 'core/theme/app_theme.dart';
import 'core/ui/app_snackbar.dart';
import 'core/utils/system_insets.dart';
import 'features/downloader/presentation/downloader_home_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/updater/presentation/app_update_screen.dart';
import 'features/player/presentation/floating_pip_overlay.dart';
import 'features/player/presentation/player_provider.dart';
import 'features/player/presentation/shortcut_item.dart';
import 'core/services/diagnostics/lab_stream.dart';
import 'core/services/diagnostics/playback_log.dart';
import 'core/services/video_player/stream_renewal.dart';
import 'core/services/network/throughput_memory.dart';
import 'features/video_hub/presentation/playback.dart';
import 'features/video_hub/presentation/video_hub_provider.dart';

class InnocentApp extends ConsumerStatefulWidget {
  final bool showOnboarding;
  const InnocentApp({super.key, this.showOnboarding = false});

  @override
  ConsumerState<InnocentApp> createState() => _InnocentAppState();
}

class _InnocentAppState extends ConsumerState<InnocentApp> {
  late bool _showOnboarding = widget.showOnboarding;
  final ExternalIntentService _intentService = ExternalIntentService();
  StreamSubscription<ExternalVideoRequest>? _intentSub;
  StreamSubscription<String>? _sharedLinkSub;
  StreamSubscription<void>? _appUpdateSub;

  ThemeMode _resolveThemeMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.adaptive:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }

  @override
  void initState() {
    super.initState();
    // Phase 29: subscribe to external "open video" intents.
    // Skip during onboarding — first impression matters more than auto-play.
    // A device-lab build also listens during onboarding: Test Lab's
    // playback measurement launches a fresh install straight into a film.
    if (!_showOnboarding || const bool.fromEnvironment('INNOCENT_LAB')) {
      _startIntentListener();
    }
    if (const bool.fromEnvironment('INNOCENT_LAB')) unawaited(_labStream());
    // Local Network: hand the saved servers to the native side, so a film
    // from a NAS resumed straight from History after a restart can open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(netServersProvider);
    });
  }

  /// DEVICE LAB ONLY — play the film the lab named through the stream proxy
  /// (see [LabStream]). Nothing happens when it named none.
  Future<void> _labStream() async {
    final titleId = await LabStream.titleId();
    if (titleId != null) return _labTitle(titleId);
    final local = await LabStream.localUrl();
    if (local == null || !mounted) return;
    if (_showOnboarding) setState(() => _showOnboarding = false);
    // The router's app is not up until the introduction is out of the way.
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    PlaybackLog.add('LAB stream: opening the player');
    unawaited(ref.read(routerProvider).push(
      Routes.player,
      extra: <String, dynamic>{
        'uri': local,
        'title': 'Lab stream',
        'ephemeral': true,
      },
    ));
    WidgetsBinding.instance.ensureVisualUpdate();
    for (final seek in await LabStream.seekPlan()) {
      Timer(seek.$1, () {
        if (!mounted) return;
        PlaybackLog.add('LAB stream: seek to ${seek.$2.inSeconds} s');
        unawaited(ref.read(videoPlayerServiceProvider).seek(seek.$2));
      });
    }
  }

  /// DEVICE LAB ONLY — a catalogue title, played exactly as a viewer's tap
  /// plays it (see [LabStream.titleId]).
  Future<void> _labTitle(String id) async {
    if (_showOnboarding) setState(() => _showOnboarding = false);
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    try {
      final seed = await LabStream.seedKbps();
      if (seed != null) {
        await ThroughputMemory.read();
        ThroughputMemory.labSeed(seed);
        PlaybackLog.add('LAB title: link estimate seeded at $seed kbps');
      }
      final content = await ref.read(contentRepositoryProvider).getById(id);
      final ctx =
          ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
      if (content == null || ctx == null || !ctx.mounted) {
        PlaybackLog.add('LAB title: ${content == null ? 'not found' : 'no screen'}');
        return;
      }
      PlaybackLog.add('LAB title: opening ${content.title}');
      await playMedia(ctx, ref, content: content, source: content.source,
          fromStart: true);
    } catch (e) {
      PlaybackLog.add('LAB title failed: $e');
    }
  }

  /// DEVICE LAB ONLY — the jumps a viewer makes mid-stream, each checked for
  /// where it LANDED: a seek, a change of quality, a skip, a swipe, a change
  /// back to Auto. Every one writes `LAB check <what> PASS|FAIL want=… got=…`
  /// (seconds), which device-cloud.yml keeps in lab_trace.txt. Written after
  /// 1.64.68 reopened the film at 00:00 after a quality change and after a
  /// slow seek — on every phone, and no run had looked at the position.
  Future<void> _labJumpScript() async {
    final svc = ref.read(videoPlayerServiceProvider);
    // THE PLAYER SCREEN'S CONTROLLER, read at each step. It is autoDispose,
    // and read once here — before the screen had mounted and watched it —
    // it was a controller of its own with nothing open: every change of
    // quality was refused as "cannot be renewed" and the swipe seeked live
    // as for a file (run 39206916255, both phones).
    PlayerController player() => ref.read(playerControllerProvider.notifier);
    var pass = 0, fail = 0;
    Future<bool> until(bool Function() ok, Duration within) async {
      final end = DateTime.now().add(within);
      while (DateTime.now().isBefore(end)) {
        if (!mounted) return false;
        if (ok()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return ok();
    }

    // LANDED AND PLAYING. A position read once said PASS for a film stuck
    // at the seek target, buffering for 45 s (run 39202304734): the check
    // now waits for the picture to MOVE past where it landed, and reports
    // how long that took after the jump — the number a viewer feels.
    Future<void> check(String what, Duration want, DateTime jumped,
        {Duration late = const Duration(seconds: 30)}) async {
      // Near the target AND past it: right after a jump back the player
      // still reports where it was, which is past the target too.
      final moved = await until(
          () =>
              svc.position > want + const Duration(milliseconds: 500) &&
              LabStream.landed(want, svc.position, late: late),
          const Duration(seconds: 30));
      final ready = DateTime.now().difference(jumped).inMilliseconds;
      final landedAt = svc.position;
      // A second of film played since, within six: a reopen has its
      // decoders to start (1.8 s to the sound on a realme C53, run
      // 39741227453), and one look two seconds on called that stuck.
      final playing = await until(
          () => svc.position - landedAt >= const Duration(seconds: 1),
          const Duration(seconds: 6));
      final resumed = DateTime.now().difference(jumped).inMilliseconds - 1000;
      final ok = moved && playing && LabStream.landed(want, landedAt, late: late);
      ok ? pass++ : fail++;
      final rung = StreamRenewal.quality.value?.playing ?? '-';
      PlaybackLog.add('LAB check $what ${ok ? 'PASS' : 'FAIL'} '
          'want=${want.inSeconds} got=${landedAt.inSeconds} '
          'ready=${moved ? '$ready ms' : 'never'} '
          'playing=${playing ? 'yes, moving by $resumed ms' : 'no'} rung=$rung');
    }

    String? otherRung() {
      final menu = StreamRenewal.quality.value;
      if (menu == null) return null;
      for (final o in menu.options.reversed) {
        if (o.id == 'auto' || o.id == 'original') continue;
        if (o.label == menu.playing) continue;
        return o.id;
      }
      return null;
    }

    try {
      // Playing, past its start.
      if (!await until(() => svc.position > const Duration(seconds: 5),
          const Duration(seconds: 90))) {
        PlaybackLog.add('LAB check: the film never started');
        return;
      }
      final length = svc.duration;
      Duration at(double share) => Duration(
          milliseconds: (length.inMilliseconds * share).round());

      // 1. The seek bar, released at 40 %.
      var want = at(0.4);
      var jumped = DateTime.now();
      await player().seek(want);
      await check('seek', want, jumped);

      // 2. A change of quality, from the menu.
      final rung = otherRung();
      if (rung == null) {
        PlaybackLog.add('LAB check quality SKIP (one copy)');
      } else {
        want = svc.position;
        jumped = DateTime.now();
        final ok = await player().switchQuality(rung);
        // The film plays on through the switch's fetch (up to 8 s).
        await check('quality->$rung${ok ? '' : ' (refused)'}', want, jumped,
            late: const Duration(seconds: 40));
      }

      // 3. +30 s, as the skip button does.
      want = svc.position + const Duration(seconds: 30);
      jumped = DateTime.now();
      await player().seekRelative(30);
      await check('skip+30', want, jumped);

      // 4. A swipe across the picture, 2 minutes back.
      final from = svc.position;
      want = from - const Duration(minutes: 2);
      player().onSeekStart();
      for (var s = 10; s <= 120; s += 10) {
        player().onSeekUpdate(-s);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      jumped = DateTime.now();
      await player().onSeekEnd();
      await check('swipe-120', want, jumped);

      // 5. Back to Auto.
      want = svc.position;
      jumped = DateTime.now();
      await player().switchQuality('auto');
      await check('quality->auto', want, jumped, late: const Duration(seconds: 40));
    } catch (e) {
      PlaybackLog.add('LAB check failed to run: $e');
    } finally {
      PlaybackLog.add('LAB check summary pass=$pass fail=$fail');
    }
  }

  /// DEVICE LAB ONLY — Test Lab's playback measurement (device-cloud.yml,
  /// MODE=playback). The same film is played three ways, about fifty
  /// seconds each, while CpuProbe and the pipeline line log to logcat:
  /// "Default" as opened (`auto-safe`: MediaCodec decoding, every frame then
  /// copied back to memory), "HW+" (`auto`: MediaCodec straight into the
  /// picture, no copy), and "SW" (the CPU decodes). Then the app closes, which
  /// ends the test.
  void _labPlaybackScript() {
    PlaybackLog.add('LAB script: phase default');
    Timer(const Duration(seconds: 55), () {
      if (!mounted) return;
      PlaybackLog.add('LAB script: phase hwplus');
      ref.read(playerControllerProvider.notifier).selectDecoder(DecoderType.hwPlus);
    });
    Timer(const Duration(seconds: 110), () {
      if (!mounted) return;
      PlaybackLog.add('LAB script: phase sw');
      ref.read(playerControllerProvider.notifier).selectDecoder(DecoderType.sw);
    });
    Timer(const Duration(seconds: 165), () => exit(0));
  }

  void _startIntentListener() {
    // The engine is made current from app launch, so it is usually finished
    // before anyone reaches the downloader. Doing this only when that screen
    // opens is what let a shared link be read on a stale engine.
    EngineReadiness.instance.start();
    _intentService.start();
    _intentSub = _intentService.videoRequests.listen((req) {
      // DEVICE LAB, scenario 3: the catalogue title compiled into this lab
      // APK, played through playMedia on a real phone's real connection; the
      // app closes after four minutes, which ends the test.
      if (const bool.fromEnvironment('INNOCENT_LAB') &&
          req.uri == 'innocent-lab://title') {
        PlaybackLog.add('LAB script: catalogue title');
        // Compiled in for Test Lab; the device lab names it in
        // lab_stream_url instead, to take this same path on the emulator.
        const built = String.fromEnvironment('INNOCENT_LAB_TITLE');
        unawaited(() async {
          final id = built.isNotEmpty
              ? built
              : await LabStream.titleId(file: 'lab_loop_title');
          if (id == null || id.isEmpty) {
            PlaybackLog.add('LAB title: none named');
            return;
          }
          await _labTitle(id);
          // Test Lab only (the title compiled in): the jumps a viewer
          // makes, each checked for where it landed.
          if (built.isNotEmpty) await _labJumpScript();
        }());
        if (built.isNotEmpty) {
          Timer(const Duration(seconds: 240), () => exit(0));
        }
        return;
      }
      // Wait for the router/widget tree to be ready before pushing.
      // DEVICE LAB: Test Lab installs fresh, so the introduction is up, and
      // it is not on the router — a push would land behind it, unseen. Step
      // past it first (for this run only; nothing is saved).
      final labFilm = const bool.fromEnvironment('INNOCENT_LAB') &&
          req.uri.endsWith('/innocent_lab_play.mp4');
      if (labFilm && _showOnboarding && mounted) {
        setState(() => _showOnboarding = false);
      }
      // The lab film waits for the router's app to be up after that switch;
      // a push into a router nothing is showing yet goes nowhere.
      Future<void>.delayed(
          labFilm ? const Duration(seconds: 3) : Duration.zero, () {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
        // A share-intent can arrive as the app is closing; touching `ref`
        // after this State is disposed throws and kills whatever is building.
        if (!mounted) return;
        final router = ref.read(routerProvider);
        router.push(
          Routes.player,
          extra: {'uri': req.uri, 'title': req.title},
        );
        if (labFilm) {
          PlaybackLog.add('LAB script: player pushed');
          _labPlaybackScript();
        }
        });
        // A post-frame callback waits for a frame, and a still screen draws
        // none: ask for one, or the push can wait until somebody touches it.
        WidgetsBinding.instance.ensureVisualUpdate();
      });
    });

    // v0.99.5: a link shared in from another app opens the downloader on it.
    // Pushed on the root navigator rather than routed, because the downloader
    // is a pushed screen rather than a declared route — the same way the Me
    // tab opens it.
    _sharedLinkSub = _intentService.sharedLinks.listen((String url) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        rootNavigatorKey.currentState?.push(
          MaterialPageRoute<void>(
            builder: (_) => DownloaderHomeScreen(initialUrl: url),
          ),
        );
      });
    });

    // docs/updater_plan.md step 6: tapping the update notification opens
    // Settings → App update. Pushed on the ROOT navigator, the same way a
    // shared link opens the downloader above — the update screen is a pushed
    // screen rather than a declared route, and the root navigator is what puts
    // it above the shell instead of inside one tab.
    _appUpdateSub = _intentService.appUpdateRequests.listen((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        rootNavigatorKey.currentState?.push(
          MaterialPageRoute<void>(builder: (_) => const AppUpdateScreen()),
        );
      });
    });
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _sharedLinkSub?.cancel();
    _appUpdateSub?.cancel();
    _intentService.dispose();
    super.dispose();
  }

  /// Push settings that live outside Riverpod into the services that read
  /// them: the thumbnail cache is a plain service (it runs from background
  /// paths with no ref), and the library data source is deliberately
  /// Riverpod-free so it stays testable. Both are set once at startup and
  /// again whenever the relevant setting changes.
  void _syncPlainServiceSettings() {
    final ps = ref.read(playerSettingsProvider);
    thumbnailDiskCacheEnabled =
        ps.get(PlayerSetting.generalCacheThumbnail);
    final exts =
        ref.read(extraSettingsProvider).getStr(StringSetting.scanExtensions);
    LibraryLocalDataSource.setExtensionFilter(
      exts.trim().isEmpty ? null : exts.split(RegExp(r'[|,\s]+')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // These two settings had no reader at all: "Cache thumbnail" never stopped
    // thumbnails being written to disk, and the "File extensions" list never
    // reached the scanner. Re-applied on every settings change so flipping
    // either takes effect without a restart.
    ref.listen(playerSettingsProvider, (_, __) => _syncPlainServiceSettings());
    ref.listen(extraSettingsProvider, (_, __) => _syncPlainServiceSettings());
    _syncPlainServiceSettings();

    final prefs = ref.watch(preferencesProvider);
    final themeMode = _resolveThemeMode(prefs.themeMode);
    final locale = ref.watch(localeProvider);

    if (_showOnboarding) {
      return MaterialApp(
        title: 'Innocent',
        scaffoldMessengerKey: AppSnackbar.messengerKey,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode,
        locale: locale,
        localizationsDelegates: AppStrings.localizationsDelegates,
        supportedLocales: AppStrings.supportedLocales,
        debugShowCheckedModeBanner: false,
        home: OnboardingScreen(
          onComplete: () {
            setState(() => _showOnboarding = false);
            // Start listening for external intents AFTER onboarding finishes.
            _startIntentListener();
          },
        ),
      );
    }

    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Innocent',
      scaffoldMessengerKey: AppSnackbar.messengerKey,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: AppStrings.localizationsDelegates,
      supportedLocales: AppStrings.supportedLocales,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
      // Render the in-app floating PiP overlay ABOVE the whole navigator, so
      // it stays visible over every route — the folder detail screen and the
      // stream screen are pushed on the ROOT navigator (outside the tab
      // shell), so an overlay living inside the shell would be hidden behind
      // them. At this level the little video window floats over whatever
      // screen the user is on (e.g. the Movies folder they came from) instead
      // of the app dropping to the launcher. The overlay renders nothing
      // until PiP is actually active.
      builder: (context, child) {
        // Snapshot the bottom system-bar inset while it's visible (this runs
        // on the normal edge-to-edge shell before the player goes immersive),
        // so the player can reserve nav-bar space even after the bar is
        // hidden and reports zero. Kept as a max, so a later immersive frame
        // reporting 0 won't erase it.
        SystemInsets.observeBottom(MediaQuery.of(context).viewPadding.bottom);
        // The D-pad's focus ring sits over everything, the PiP window too.
        return FocusRingLayer(
          child: Stack(
            children: [
              if (child != null) child,
              const FloatingPipOverlay(),
            ],
          ),
        );
      },
    );
  }
}
