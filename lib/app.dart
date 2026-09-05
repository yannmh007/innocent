import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/services/preferences/extra_settings_service.dart';
import 'core/services/preferences/player_settings_service.dart';
import 'core/services/thumbnail/thumbnail_cache.dart';
import 'features/local_browser/data/library_local_datasource.dart';

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
import 'features/player/presentation/floating_pip_overlay.dart';

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
    if (!_showOnboarding) {
      _startIntentListener();
    }
  }

  void _startIntentListener() {
    // The engine is made current from app launch, so it is usually finished
    // before anyone reaches the downloader. Doing this only when that screen
    // opens is what let a shared link be read on a stale engine.
    EngineReadiness.instance.start();
    _intentService.start();
    _intentSub = _intentService.videoRequests.listen((req) {
      // Wait for the router/widget tree to be ready before pushing.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // A share-intent can arrive as the app is closing; touching `ref`
        // after this State is disposed throws and kills whatever is building.
        if (!mounted) return;
        final router = ref.read(routerProvider);
        router.push(
          Routes.player,
          extra: {'uri': req.uri, 'title': req.title},
        );
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
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _sharedLinkSub?.cancel();
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
        return Stack(
          children: [
            if (child != null) child,
            const FloatingPipOverlay(),
          ],
        );
      },
    );
  }
}
