import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/localization/app_strings.dart';
import '../../core/router/routes.dart';
import '../../core/theme/app_colors.dart';
import '../local_browser/presentation/library_provider.dart';
import '../local_browser/presentation/local_screen.dart';
import '../me/presentation/me_screen.dart';
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
    // Keep the iADB auto-scan coordinator alive for the whole session: when
    // iADB connects (from anywhere), Android/data videos are scanned and shown
    // in Local automatically, no ADB-screen visit needed. The shell is always
    // mounted, so this watch never lets the coordinator drop.
    ref.watch(adbAutoScanProvider);

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: currentIndex,
        backgroundColor: AppColors.specNavBar,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.specPrimary,
        unselectedItemColor: AppColors.specNavInactive,
        // MX-Player-sized nav bar: larger icons + labels (was 24 / 11) so the
        // bar reads taller and more prominent, matching MX's bottom tabs.
        iconSize: 28,
        selectedFontSize: 13,
        unselectedFontSize: 12,
        showUnselectedLabels: true,
        onTap: (index) {
          ref.read(shellTabIndexProvider.notifier).state = index;
          context.go(_shellTabs[index].route);
        },
        items: [
          for (int i = 0; i < _shellTabs.length; i++)
            BottomNavigationBarItem(
              icon: Icon(_shellTabs[i].icon),
              activeIcon: Icon(_shellTabs[i].activeIcon),
              label: _navLabel(context, i),
            ),
        ],
      ),
    );
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
