import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/ui/app_snackbar.dart';
import '../../../user_data/user_data_providers.dart';
import '../../domain/video.dart';
import '../library_provider.dart';
import 'bulk_actions.dart';
import '../selection_provider.dart';

/// Top bar shown while videos are selected.
///
/// ─── WHAT CHANGED, AND WHY IT MATTERED ───────────────────────────────────
///
/// The previous version put seven actions in `actions:` and implemented five
/// of them with a snackbar and nothing else. "Hide" reported files hidden and
/// hid nothing. "Rebuild thumbnails" reported a rebuild and rebuilt nothing.
/// "Share" told the user to go and use a different menu. "Play" pushed
/// `Navigator.pushNamed('/player')` in an app routed entirely by GoRouter,
/// where no such route is registered — so the primary action of the whole mode
/// did nothing at all.
///
/// Telling someone an operation succeeded when it did not is worse than not
/// offering it: they act on it. Someone who "hid" a file and handed the phone
/// over was told the file was hidden.
///
/// So this bar now carries only WHAT IS SELECTED and the overflow; the actions
/// live in [SelectionActionBar] at the bottom, where there is room for them,
/// and each one is wired to the implementation that already existed.
class SelectionAppBar extends ConsumerWidget implements PreferredSizeWidget {
  /// Total number of videos on screen, for the "2 / 99" counter. Knowing the
  /// denominator is what tells you whether "select all" is worth pressing.
  final int totalVisible;

  const SelectionAppBar({super.key, this.totalVisible = 0});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  /// The selected videos, resolved once.
  List<Video> _selected(WidgetRef ref) {
    final selection = ref.read(selectionProvider);
    final all = ref.read(allVideosProvider).valueOrNull ?? const <Video>[];
    return all.where((v) => selection.contains(v.uri)).toList();
  }

  /// Play the selection, starting from the first item.
  ///
  /// `context.push(Routes.player, extra: {...})` — the same call every other
  /// play site in this feature makes. The old `pushNamed('/player')` could
  /// never have worked: this app registers no named routes.
  void _play(BuildContext context, WidgetRef ref) {
    final videos = _selected(ref);
    if (videos.isEmpty) return;
    final first = videos.first;
    ref.read(selectionProvider.notifier).clear();
    context.push(
      Routes.player,
      extra: <String, dynamic>{'uri': first.uri, 'title': first.title},
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final count = ref.watch(selectionProvider).length;
    return AppBar(
      backgroundColor: AppColors.darkSurface,
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: s.cancel,
        onPressed: () => ref.read(selectionProvider.notifier).clear(),
      ),
      // "2 / 99 Selected" — the denominator is the point. Without it there is
      // no way to tell a nearly-complete selection from a barely-started one.
      title: Text(
        totalVisible > 0 ? '$count / $totalVisible' : '$count',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.play_arrow),
          tooltip: s.play,
          onPressed: () => _play(context, ref),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          color: AppColors.darkSurface,
          onSelected: (v) async {
            final videos = _selected(ref);
            if (videos.isEmpty) return;
            var handled = false;
            switch (v) {
              case 'share':
                handled = await BulkActions.share(context, ref, videos: videos);
              case 'lock':
                handled = await BulkActions.lockInPrivateFolder(context, ref,
                    videos: videos);
              case 'transfer':
                handled = await BulkActions.sendToTransfer(context, ref,
                    videos: videos);
              case 'hide':
                handled = await BulkActions.hide(context, ref, videos: videos);
              case 'rebuild':
                handled = await BulkActions.rebuildThumbnails(context, ref,
                    videos: videos);
              case 'properties':
                handled = await BulkActions.properties(context, ref,
                    videos: videos);
            }
            // Only clear on success. A cancelled vault prompt or a refused
            // share used to throw the selection away anyway, so the user had
            // to pick all twenty files again to try a different action.
            if (handled) ref.read(selectionProvider.notifier).clear();
          },
          itemBuilder: (_) => <PopupMenuEntry<String>>[
            _item('share', Icons.share_outlined, s.share),
            _item('lock', Icons.lock_outline, s.lockInPrivateFolder),
            _item('transfer', Icons.send_to_mobile, s.tabTransfer),
            const PopupMenuDivider(),
            _item('hide', Icons.visibility_off_outlined, s.hide),
            _item('rebuild', Icons.refresh, s.rebuildThumbnail),
            _item('properties', Icons.info_outline, s.properties),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<String> _item(String value, IconData icon, String label) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: <Widget>[
          Icon(icon, color: Colors.white70, size: 20),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}
