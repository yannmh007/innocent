import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/routes.dart';
import '../../../me/presentation/media_manager_screen.dart';
import '../../../me/presentation/status_saver_screen.dart';
import '../../../network_stream/presentation/network_stream_screen.dart';
import '../../../settings/presentation/settings_screen.dart';
import '../../../shell/shell_screen.dart';
import '../../../transfer/presentation/transfer_screen.dart';
import '../../../user_data/presentation/favourites_screen.dart';
import '../../../user_data/presentation/history_screen.dart';
import '../../../user_data/presentation/playlists_screen.dart';
import '../../../user_data/presentation/watch_later_screen.dart';
import '../../../../core/theme/app_colors.dart';

import '../../../../core/localization/app_strings.dart';

/// Phase 17: Quick-access chips at the top of the folder list/grid.
///
/// Updates over Phase 16:
/// - Shown in BOTH list AND grid mode (MX Player V3 t=2 reference)
/// - Swipeable carousel with pagination dots underneath
/// - Each chip uses a 52dp surface disc with a white illustrative icon
///
/// PAGING IS COMPUTED, NOT HARD-CODED (changed when the Video chip was
/// added). The strip used to be two hand-written pages of six. Six 52dp discs
/// plus padding fit a 360dp screen with almost nothing to spare, so a seventh
/// chip overflowed on small phones - and hand-balanced pages have to be
/// re-balanced by hand every time an entry is added or removed.
///
/// Now the chips are ONE flat list and the page size is derived from the
/// available width, clamped to 4-6. Adding a future entry means appending to
/// that list; the layout re-flows itself and cannot overflow.
class QuickAccessChips extends ConsumerStatefulWidget {
  /// Called just before any chip navigates away, so the host (Local screen) can
  /// collapse its momentary Continue Watching strip.
  final VoidCallback? onNavigate;

  const QuickAccessChips({super.key, this.onNavigate});

  @override
  ConsumerState<QuickAccessChips> createState() => _QuickAccessChipsState();
}

class _QuickAccessChipsState extends ConsumerState<QuickAccessChips> {
  final _controller = PageController();
  int _page = 0;

  /// Disc width plus the minimum gap either side of it.
  static const double _slotWidth = 56;

  /// Matches the horizontal padding used by [_ChipPage].
  static const double _pagePadding = 28;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open(BuildContext context, Widget screen) {
    widget.onNavigate?.call();
    // rootNavigator:true -> push ABOVE the shell so the persistent bottom nav
    // bar (Local / Music / Transfer / Me) is hidden for these full-screen
    // sub-features. Without it the push lands on the shell's nested navigator,
    // the tab bar stays visible, and tapping another tab appears to do nothing
    // (the sub-screen sits on top). Matches the Me tab's behaviour.
    Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildItems(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final usable = constraints.maxWidth - _pagePadding;
        // clamp: never so few that the strip becomes a scroll-fest, never so
        // many that the discs collide on a narrow phone.
        // Explicit int math: `int.clamp(int, int)` is declared on num, and
        // `sublist` needs a real int. Spelling it out removes any dependence
        // on how the analyser types clamp.
        int perPage = (usable / _slotWidth).floor();
        if (perPage < 4) perPage = 4;
        if (perPage > 6) perPage = 6;
        final pageCount = (items.length + perPage - 1) ~/ perPage;

        // A stale page index (rotation, split-screen, a chip removed) would
        // otherwise leave the dots highlighting a page that no longer exists.
        final safePage = _page >= pageCount ? pageCount - 1 : _page;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 88,
              child: PageView.builder(
                controller: _controller,
                itemCount: pageCount,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) {
                  final start = i * perPage;
                  final end = (start + perPage) > items.length
                      ? items.length
                      : (start + perPage);
                  return _ChipPage(
                    items: items.sublist(start, end),
                    slots: perPage,
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            // Pagination dots (MX Player V3 t=2 reference)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(pageCount, (i) {
                final active = i == safePage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 16 : 6,
                  height: 4,
                  decoration: BoxDecoration(
                    color: active ? Colors.white70 : Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }

  /// The chips, in priority order. Appending here is all it takes to add one.
  List<_ChipItem> _buildItems(BuildContext context) {
    final s = AppStrings.of(context);
    return <_ChipItem>[
      // Video Hub - the remote movie/series/reels vertical. First because it
      // is the reason most people will open this strip at all.
      _ChipItem(
        label: s.vhVideoChip,
        icon: Icons.movie_outlined,
        bg: const Color(0xFFD32F2F), // red - cinema
        onTap: () {
          widget.onNavigate?.call();
          // Top-level GoRoute pinned to the root navigator, so the hub opens
          // ABOVE the shell and the bottom nav bar is hidden - same reasoning
          // as the Privacy chip below.
          context.push(Routes.videoHub);
        },
      ),
      _ChipItem(
        label: 'Music',
        // MX shows headphones with musical-note sparkles; closest Material icon
        icon: Icons.headphones,
        bg: const Color(0xFFFF9800), // orange
        onTap: () {
          widget.onNavigate?.call();
          // Switch to Music tab (index 1) - both provider AND router
          ref.read(shellTabIndexProvider.notifier).state = 1;
          context.go(Routes.music);
        },
      ),
      _ChipItem(
        label: 'File Transfer',
        // MX shows folder with arrows (transfer between folders)
        icon: Icons.drive_file_move_outlined,
        bg: const Color(0xFF1976D2), // blue
        onTap: () => _open(context, const TransferScreen()),
      ),
      _ChipItem(
        label: 'Status Saver',
        // MX shows download-into-rounded-square
        icon: Icons.system_update_alt,
        bg: const Color(0xFF43A047), // green
        onTap: () => _open(context, const StatusSaverScreen()),
      ),
      _ChipItem(
        label: 'My Playlists',
        // MX shows clipboard-with-plus
        icon: Icons.playlist_add,
        bg: const Color(0xFF8E24AA), // purple
        onTap: () => _open(context, const PlaylistsScreen()),
      ),
      _ChipItem(
        label: 'Privacy',
        // MX uses a closed-padlock-shield
        icon: Icons.shield_outlined,
        bg: const Color(0xFF1565C0), // dark blue
        // Route through the top-level GoRoute (pinned to the root
        // navigator) so the vault opens ABOVE the shell and its bottom nav
        // bar is hidden - NOT a Navigator.push, which would land inside the
        // shell and leave two stacked bottom bars.
        onTap: () {
          widget.onNavigate?.call();
          context.push(Routes.privateFolder);
        },
      ),
      _ChipItem(
        label: 'History',
        icon: Icons.history,
        bg: const Color(0xFF00897B), // teal
        onTap: () => _open(context, const HistoryScreen()),
      ),
      _ChipItem(
        label: 'Favourites',
        icon: Icons.favorite,
        bg: const Color(0xFFE53935), // red
        onTap: () => _open(context, const FavouritesScreen()),
      ),
      _ChipItem(
        label: 'Watch Later',
        icon: Icons.watch_later,
        bg: const Color(0xFFF57C00), // orange
        onTap: () => _open(context, const WatchLaterScreen()),
      ),
      _ChipItem(
        label: 'Network',
        icon: Icons.public,
        bg: const Color(0xFF5E35B1), // deep purple
        onTap: () => _open(context, const NetworkStreamScreen()),
      ),
      _ChipItem(
        label: 'Cleaner',
        // MX uses a green broom-like icon
        icon: Icons.cleaning_services,
        bg: const Color(0xFF388E3C), // green
        onTap: () => _open(context, const MediaManagerScreen()),
      ),
      _ChipItem(
        label: 'Equalizer',
        icon: Icons.tune,
        bg: const Color(0xFF00ACC1), // cyan
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppStrings.of(context).eqDuringPlayback),
              duration: const Duration(seconds: 1),
            ),
          );
        },
      ),
      _ChipItem(
        label: 'Settings',
        icon: Icons.settings,
        bg: const Color(0xFF546E7A), // blue grey
        onTap: () => _open(context, const SettingsScreen()),
      ),
    ];
  }
}

class _ChipPage extends StatelessWidget {
  final List<_ChipItem> items;

  /// Slots this page must occupy, so a short final page keeps the same column
  /// positions as a full one instead of re-spacing its chips.
  final int slots;

  const _ChipPage({required this.items, required this.slots});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      for (final it in items) _Chip(item: it),
      for (int i = items.length; i < slots; i++) const SizedBox(width: 52),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: children,
      ),
    );
  }
}

class _ChipItem {
  final String label;
  final IconData icon;
  final Color bg;
  final VoidCallback onTap;

  _ChipItem({
    required this.label,
    required this.icon,
    required this.bg,
    required this.onTap,
  });
}

class _Chip extends StatelessWidget {
  final _ChipItem item;
  const _Chip({required this.item});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: item.onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 52,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // innocent_folders_spec: 52 dp surface (#444D56) disc with a
            // clean white glyph inside (the spec discs are uniform grey,
            // not per-item colour).
            Container(
              width: 52,
              height: 52,
              decoration: const BoxDecoration(
                color: AppColors.specSurface,
                shape: BoxShape.circle,
              ),
              child: Icon(item.icon, color: Colors.white, size: 26),
            ),
            const SizedBox(height: 6),
            Text(
              item.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.specTextSecondary,
                fontSize: 11,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
