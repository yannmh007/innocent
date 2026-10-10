import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ui/device_profile.dart';
import '../../core/localization/app_strings.dart';
import '../../core/router/routes.dart';
import '../../core/theme/app_colors.dart';
import '../local_browser/presentation/android_data_sync.dart';
import '../local_browser/presentation/library_watcher.dart';
import '../video_hub/data/api/offline_auto_resume.dart';
import '../video_hub/data/api/offline_downloader.dart';
import '../local_browser/presentation/local_screen.dart';
import '../me/presentation/me_screen.dart';
import '../updater/presentation/update_prompt.dart';
import '../music/presentation/music_screen.dart';
import '../transfer/presentation/transfer_screen.dart';

/// Provider for current selected tab index
final shellTabIndexProvider = StateProvider<int>((ref) => 0);

/// Bottom-nav tab definitions — the single source of truth for the shell's
/// tabs. Adding a new tab (e.g. the upcoming "Innocent" stream/download tab)
/// is a one-line append here, PLUS a matching GoRoute + ShellTabPage(tabIndex:)
/// in app_router.dart. Order is index-significant: other screens navigate by
/// index (Music = 1, Transfer = 2), so only ever APPEND — never reorder.
class _ShellTab {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String route;
  const _ShellTab(this.icon, this.activeIcon, this.label, this.route);
}

const List<_ShellTab> _shellTabs = [
  _ShellTab(Icons.folder_outlined, Icons.folder, 'Local', Routes.local),
  _ShellTab(Icons.music_note_outlined, Icons.music_note, 'Music', Routes.music),
  // Phase 34: send_to_mobile is the closest Material icon to MX's transfer
  // pictogram (verified frame 1).
  _ShellTab(Icons.send_to_mobile_outlined, Icons.send_to_mobile, 'Transfer',
      Routes.transfer),
  _ShellTab(Icons.person_outline, Icons.person, 'Me', Routes.me),
];

const int _transferTab = 2;

/// Shell wraps tabs with persistent bottom nav.
class ShellScreen extends ConsumerStatefulWidget {
  final Widget child;

  const ShellScreen({super.key, required this.child});

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The main shell must always be edge-to-edge (system bars visible, app
    // laid out behind them with the bottom nav padded above the nav bar).
    // The fullscreen player switches to immersiveSticky while it's open;
    // if we return here without the system restoring edge-to-edge, the app
    // would inherit immersive mode — the nav bar hides, and a reveal-swipe
    // then overlays the bottom tabs instead of the tabs sitting above it.
    // Asserting it here (init) closes that gap.
    _restoreEdgeToEdge();
    // The first resume of a cold start does not fire the lifecycle callback,
    // so the prompt would otherwise wait for the user to background the app
    // and come back before it could ever appear.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptUpdate());
    // AND PICK UP ANY DOWNLOAD THAT WAS INTERRUPTED.
    //
    // The shell is the right place for this and the only one: it is the first
    // thing that exists in a session, it survives the whole of it, and unlike a
    // provider it knows the viewer's language — which a resumed download needs
    // for its notification. Hooked to the post-frame callback for the same
    // reason the update prompt is: the first resume of a cold start never fires
    // the lifecycle callback, so anything that waits for one waits until the
    // user has backgrounded the app and come back.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _maybeResumeDownloads());
  }

  /// Carry on with downloads the network or the app interrupted — never with
  /// one the viewer paused. See [OfflineAutoResume].
  void _maybeResumeDownloads() {
    if (!mounted) return;
    final s = AppStrings.of(context);
    // ignore: discarded_futures
    OfflineAutoResume.maybeRun(
      ref,
      notices: DownloadNotices(
        waiting: s.vhDownloadWaitingSignal,
        ready: s.vhDownloadReadyOffline,
      ),
    );
  }

  /// §4B: on resume, on a list screen. This is that list screen — the shell
  /// hosts Local / Music / Transfer / Me, and the fullscreen player is pushed
  /// on the ROOT navigator ABOVE it.
  ///
  /// THE isCurrent GUARD IS WHAT KEEPS THE PROMPT OFF THE PLAYER, and it is
  /// the same guard the edge-to-edge restore above already relies on for the
  /// same reason: the shell stays mounted under the player and its lifecycle
  /// callback still fires, so "am I the visible route" is the question that
  /// actually distinguishes the two. A flag saying "the player is open" would
  /// be a second source of truth that could go stale; this one cannot.
  void _maybePromptUpdate() {
    if (!mounted) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    UpdatePrompt.maybeShow(context, ref);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-assert on every resume — but ONLY when the shell is actually the
    // visible screen. The fullscreen player is pushed on the ROOT navigator,
    // on top of (and outside) the shell, so the shell stays mounted beneath
    // it and its lifecycle callback still fires. If we blindly forced
    // edge-to-edge here we'd fight the player's immersiveSticky on resume
    // (a race that intermittently left the wrong mode). Guarding on
    // ModalRoute.isCurrent means: when the player is on top, we leave the UI
    // mode to the player; when the shell is on top, we restore edge-to-edge
    // so the phone's nav keys show and never cover the bottom tabs.
    if (state == AppLifecycleState.resumed) {
      final isShellVisible = ModalRoute.of(context)?.isCurrent ?? true;
      if (isShellVisible) {
        _restoreEdgeToEdge();
        _maybePromptUpdate();
        // On every return to the app, not only on a cold start. Walking into
        // wifi, or getting the signal back, is noticed the next time somebody
        // glances at their phone rather than the next time they relaunch.
        _maybeResumeDownloads();
      }
    }
  }

  void _restoreEdgeToEdge() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(shellTabIndexProvider);
    // Android/data's videos join the Video tab whenever ADB comes up —
    // at start, on any connection made anywhere, on a return to the app.
    // The shell is always mounted, so this watch never lets it drop.
    ref.watch(androidDataSyncProvider);
    // New, changed and removed videos reach the library as they happen.
    ref.watch(libraryWatcherProvider);

    void select(int index) {
      ref.read(shellTabIndexProvider.notifier).state = index;
      context.go(_shellTabs[index].route);
    }

    // LARGE SCREENS. Material's adaptive rule, and what every Google app does:
    // a bottom bar on a phone (< 600 dp wide), a navigation rail down the
    // left edge on anything wider — a tablet either way up, an unfolded
    // foldable, a phone-sized window turned into a wide one — and on a TV,
    // where a remote reaches a column of tabs far more naturally than a row
    // at the bottom of the screen. A bottom bar stretched across 1280 dp put
    // four icons a hand-span apart.
    // BACK, the Android way (and YouTube's, Photos', MX's): on any tab but
    // the first, Back goes to the first tab; only there does it leave the
    // app. It used to leave from every tab — on a TV remote, one press too
    // many from Music and the app was gone. A screen opened inside a tab
    // still closes first: this only answers when nothing above it can pop.
    // A tab with pages of its own (Transfer's Send / Receive / Share with)
    // gets Back first: it goes to that tab's home, then to the first tab.
    final innerBack =
        currentIndex == _transferTab ? ref.watch(transferBackProvider) : null;
    Widget backToFirstTab(Widget shell) => PopScope(
          canPop: currentIndex == 0 && innerBack == null,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (innerBack != null) {
              innerBack();
            } else {
              select(0);
            }
          },
          child: shell,
        );

    final wide = MediaQuery.sizeOf(context).width >= 600 || DeviceProfile.isTv;
    if (wide) {
      return backToFirstTab(Scaffold(
        body: Row(
          children: [
            ColoredBox(
              color: AppColors.specNavBar,
              child: SafeArea(
                right: false,
                child: NavigationRail(
                  selectedIndex: currentIndex,
                  onDestinationSelected: select,
                  backgroundColor: AppColors.specNavBar,
                  labelType: NavigationRailLabelType.all,
                  groupAlignment: -0.85,
                  minWidth: 80,
                  indicatorColor: AppColors.specPrimary.withValues(alpha: 0.18),
                  selectedIconTheme: const IconThemeData(
                      color: AppColors.specPrimary, size: 24),
                  unselectedIconTheme: const IconThemeData(
                      color: AppColors.specNavInactive, size: 24),
                  selectedLabelTextStyle: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: AppColors.specPrimary, fontSize: 12),
                  unselectedLabelTextStyle: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(
                          color: AppColors.specNavInactive, fontSize: 12),
                  destinations: [
                    for (int i = 0; i < _shellTabs.length; i++)
                      NavigationRailDestination(
                        icon: Icon(_shellTabs[i].icon),
                        selectedIcon: Icon(_shellTabs[i].activeIcon),
                        label: Text(_navLabel(context, i)),
                      ),
                  ],
                ),
              ),
            ),
            // The page in its own semantics container. Each page of the
            // router's Navigator has a ModalBarrier, which wraps itself in
            // BlockSemantics — and that drops everything painted before it
            // in the same container: the rail. TalkBack on a tablet or TV
            // could not reach Video / Music / Transfer / Me at all (Pixel C
            // emulator; test/rail_semantics_test.dart).
            Expanded(
              child: Semantics(container: true, child: widget.child),
            ),
          ],
        ),
      ));
    }

    return backToFirstTab(Scaffold(
      body: widget.child,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: currentIndex,
        backgroundColor: AppColors.specNavBar,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.specPrimary,
        unselectedItemColor: AppColors.specNavInactive,
        // MX PLAYER'S NAV, measured from its screenshots (2026-10-04, 411 dp
        // phone): a 24 dp icon and an 11 sp label, the same size selected or
        // not. The 28 / 13 this used to be — set "to read taller" — was a
        // third larger than MX's and made the bar the heaviest thing on the
        // screen.
        iconSize: 24,
        selectedFontSize: 11,
        unselectedFontSize: 11,
        showUnselectedLabels: true,
        onTap: select,
        items: [
          for (int i = 0; i < _shellTabs.length; i++)
            BottomNavigationBarItem(
              icon: Icon(_shellTabs[i].icon),
              activeIcon: Icon(_shellTabs[i].activeIcon),
              label: _navLabel(context, i),
            ),
        ],
      ),
    ));
  }

  /// Localised label for each tab (the [_shellTabs] entries hold the English
  /// fallback). Index-keyed so it stays in lockstep with the append-only
  /// tab order.
  String _navLabel(BuildContext context, int index) {
    final s = AppStrings.of(context);
    switch (index) {
      case 0:
        return s.tabLocal;
      case 1:
        return s.tabMusic;
      case 2:
        return s.tabTransfer;
      case 3:
        return s.tabMe;
      default:
        return _shellTabs[index].label;
    }
  }
}

/// Renders the appropriate tab content based on tabIndex.
class ShellTabPage extends ConsumerStatefulWidget {
  final int tabIndex;

  const ShellTabPage({super.key, required this.tabIndex});

  @override
  ConsumerState<ShellTabPage> createState() => _ShellTabPageState();
}

class _ShellTabPageState extends ConsumerState<ShellTabPage> {
  @override
  void initState() {
    super.initState();
    // Sync tab index when navigated via deep link.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Rapid tab tapping can dispose this page before the frame callback
      // runs. Touching `ref` after that throws, and because the throw lands
      // while the next tab is building, Flutter replaces that tab's body with
      // the "Something didn't load" card — the exact symptom of switching
      // tabs quickly. The guard makes the callback a no-op once disposed.
      if (!mounted) return;
      ref.read(shellTabIndexProvider.notifier).state = widget.tabIndex;
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.tabIndex) {
      case 0:
        return const LocalScreen();
      case 1:
        return const MusicScreen();
      case 2:
        return const TransferScreen();
      case 3:
        return const MeScreen();
      default:
        return Scaffold(
          backgroundColor: AppColors.darkBackground,
          body: Center(child: Text(AppStrings.of(context).unknownTab)),
        );
    }
  }
}
