import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/local_browser/presentation/folder_detail_screen.dart';
import '../../features/player/presentation/player_screen.dart';
import '../../features/private_folder/presentation/private_folder_screen.dart';
import '../../features/shell/shell_screen.dart';
import '../../features/video_hub/presentation/gate/age_gate_screen.dart';
import '../../features/video_hub/presentation/video_hub_screen.dart';
import 'routes.dart';

import '../../core/localization/app_strings.dart';
/// The root navigator (renders ABOVE the shell). Full-screen routes pin to
/// this key so they always cover the shell's bottom nav bar, no matter
/// which tab context the push came from. Without this, GoRouter's push
/// sometimes lands on the shell's own navigator, leaving the tab bar
/// visible under the pushed screen — the intermittent "two bottom bars" bug.
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');
final GlobalKey<NavigatorState> _shellNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'shell');

/// Restores edge-to-edge system-UI mode after ANY route pop on the root
/// navigator. This is the single reliable owner of "we are no longer in the
/// fullscreen player" — the player is the only screen that switches to
/// immersiveSticky (hiding the phone's nav bar), and it does so in its own
/// initState when pushed. Every pop therefore means we're returning to a
/// normal screen that must show the nav bar again.
///
/// Why this exists instead of relying on the player's dispose:
///   • A plain Back press (or popping into the floating window) is an IN-APP
///     pop, so no app-resume fires — the shell's resume-time restore never
///     runs, and the immersive mode leaks: the nav bar stays hidden and a
///     reveal-swipe overlaps the bottom tabs, "self-correcting" only when
///     some later resume happens to fire the shell's restore.
///   • The player DOES call edgeToEdge in dispose, but that call is made
///     from a disposing widget while Android is still settling the
///     immersiveSticky flag, and it intermittently doesn't stick.
///   • The player can pop back to folderDetail (a root route) OR the shell,
///     so a RouteObserver on the shell alone wouldn't fire reliably.
/// Restoring here, once, on every didPop — deferred to a post-frame callback
/// so it lands at a stable point after the pop transition — closes all of
/// those gaps. Nothing is ever pushed ABOVE the player as a route (its
/// dialogs are in-tree Stack layers), so a pop never reveals the player;
/// forcing edgeToEdge on pop can never fight a screen that wants immersive.
class _EdgeToEdgeOnPop extends NavigatorObserver {
  void _restoreEdgeToEdge() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    });
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _restoreEdgeToEdge();
    super.didPop(route, previousRoute);
  }
}

final _EdgeToEdgeOnPop _edgeToEdgeOnPop = _EdgeToEdgeOnPop();

/// Global router provider
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    observers: [_edgeToEdgeOnPop],
    initialLocation: Routes.local,
    debugLogDiagnostics: true,
    routes: [
      // Shell route — holds bottom navigation
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => ShellScreen(child: child),
        routes: [
          GoRoute(
            path: Routes.local,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellTabPage(tabIndex: 0),
            ),
          ),
          GoRoute(
            path: Routes.music,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellTabPage(tabIndex: 1),
            ),
          ),
          GoRoute(
            path: Routes.transfer,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellTabPage(tabIndex: 2),
            ),
          ),
          GoRoute(
            path: Routes.me,
            pageBuilder: (context, state) => const NoTransitionPage(
              child: ShellTabPage(tabIndex: 3),
            ),
          ),
        ],
      ),

      // Folder detail (full-screen, outside shell)
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: Routes.folderDetail,
        builder: (context, state) {
          // Folder path + name are passed as QUERY parameters, not a path
          // segment. Cramming an absolute path (which is full of '/') into a
          // ':encodedPath' segment meant encoding every slash as %2F, and
          // that interacts badly with go_router's segment matching AND with
          // double-decoding — it crashed the whole screen ("Something didn't
          // load") for folders whose names contain emoji, non-ASCII scripts,
          // or a literal '%'. Query parameters are decoded exactly once by
          // Dart's Uri and carry arbitrary UTF-8 safely, so this works for
          // any folder name in any language.
          final folderPath = state.uri.queryParameters['path'] ?? '';
          final folderName = state.uri.queryParameters['name'] ?? 'Folder';
          if (folderPath.isEmpty) {
            // Defensive: never build the detail screen without a path.
            return const _MissingFolderScreen();
          }
          return FolderDetailScreen(
            folderPath: folderPath,
            folderName: folderName,
          );
        },
      ),

      // Private Folder (full-screen, OUTSIDE the shell so the bottom nav
      // bar — Local/Music/Transfer/Me — is hidden; the vault has its own
      // category bar instead of two stacked bars).
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: Routes.privateFolder,
        builder: (context, state) => const PrivateFolderScreen(),
      ),

      // Video Hub (full-screen, outside shell) — the remote-content
      // vertical reached from the Local screen's quick-access strip.
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: Routes.videoHub,
        // Wrapped in the age gate: everything behind this route is adult
        // material, so the 18+ decision happens at the door rather than on a
        // tab inside.
        builder: (context, state) =>
            const AgeGateScreen(child: VideoHubScreen()),
      ),

      // Player (full-screen, outside shell)
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: Routes.player,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          final uri = extra?['uri'] as String? ?? '';
          final title = extra?['title'] as String? ?? 'Video';
          final isPrivate = extra?['isPrivate'] as bool? ?? false;
          // Capture protection for paid content, independent of the vault.
          final secure = extra?['secure'] as bool? ?? false;
          // A signed, expiring stream URL: never write it down. Defaults to
          // false, so an ordinary file route is unaffected.
          final ephemeral = extra?['ephemeral'] as bool? ?? false;
          return PlayerScreen(
            videoUri: uri,
            title: title,
            isPrivate: isPrivate,
            secureScreen: secure,
            ephemeral: ephemeral,
          );
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Route not found: ${state.uri}'),
      ),
    ),
  );
});

/// Shown if the folder-detail route is somehow reached without a path
/// (shouldn't happen in normal use, but we never leave the user on a
/// crashed/blank screen). Offers a way back.
class _MissingFolderScreen extends StatelessWidget {
  const _MissingFolderScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: const Center(
        child: Text(
          "This folder couldn't be opened.",
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }
}
