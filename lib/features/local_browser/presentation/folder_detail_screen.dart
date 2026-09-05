import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/ui/adb_required_dialog.dart';
import '../../../core/services/preferences/extra_settings_service.dart';
import '../../../core/services/cache/media_prewarm_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../user_data/user_data_providers.dart';
import '../domain/new_badge.dart';
import '../domain/sort_options.dart';
import '../domain/video.dart';
import 'grid_tiles.dart';
import 'library_provider.dart';
import 'search_app_bar.dart';
import 'selection_provider.dart';
import 'sort_view_dialog.dart';
import 'widgets/selection_action_bar.dart';
import 'widgets/selection_app_bar.dart';
import 'video_list_item.dart';
import 'widgets/video_option_menu.dart';
import '../../../core/utils/async_value_extensions.dart';

import '../../../core/localization/app_strings.dart';
class FolderDetailScreen extends ConsumerStatefulWidget {
  final String folderPath;
  final String folderName;

  const FolderDetailScreen({
    super.key,
    required this.folderPath,
    required this.folderName,
  });

  @override
  ConsumerState<FolderDetailScreen> createState() => _FolderDetailScreenState();
}

class _FolderDetailScreenState extends ConsumerState<FolderDetailScreen> {
  bool _searchActive = false;
  // Phase 45 (audit): preserve scroll position when the user opens a
  // video and comes back. MX Player V3 returns to the same spot in the
  // list — daily-use parity. PageStorage keys persist the offset
  // automatically for ListView / GridView with PageStorageKey.
  // Scroll position is preserved per-folder: the key includes the folder
  // path so opening folder A, scrolling, then opening folder B doesn't
  // restore A's offset into B. (A single shared key would cross-contaminate
  // scroll positions between folders — MX Player keeps them independent.)
  late final PageStorageKey<String> _scrollKey =
      PageStorageKey<String>('folderDetailScroll:${widget.folderPath}');

  @override
  void initState() {
    super.initState();
    // The user just opened this folder → ensure the background warm pass is
    // running and prioritises this folder, so its sibling folders are ready
    // by the time the user backs out and opens another.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(mediaPrewarmProvider).start(priorityFolder: widget.folderPath);
    });
  }

  void _showSortSheet() {
    SortViewDialog.show(context);
  }

  /// Open a video, guarding Android/data (adb://) videos behind a live ADB
  /// connection so a dropped connection gives the one-tap reconnect prompt
  /// instead of a player that immediately fails. On-device videos open
  /// directly. Mirrors LocalScreen._openVideo so behaviour is identical
  /// whether the user taps from the flat list or from inside a folder.
  Future<void> _openVideo(Video video) async {
    if (video.uri.startsWith('adb://')) {
      final ok = await AdbRequiredDialog.ensureConnected(
        context,
        what: 'this video',
      );
      if (!ok || !mounted) return;
      if (!await AdbRequiredDialog.isConnected() || !mounted) return;
    }
    if (!mounted) return;
    context.push(
      Routes.player,
      extra: {'uri': video.uri, 'title': video.title},
    );
  }

  @override
  Widget build(BuildContext context) {
    final videosAsync = ref.watch(filteredVideosProvider(widget.folderPath));

    final selectionActive = ref.watch(selectionProvider).isNotEmpty;

    return PopScope(
      // Back leaves SELECTION MODE before it leaves the folder. Without this
      // the screen popped with the selection still set, so the Local tab
      // underneath came up already in selection mode, holding items the user
      // could no longer see — and the bottom bar's Move would then act on
      // files from a folder they had just left.
      canPop: !selectionActive,
      onPopInvoked: (didPop) {
        if (!didPop && selectionActive) {
          ref.read(selectionProvider.notifier).clear();
        }
      },
      child: Scaffold(
      backgroundColor: AppColors.darkBackground,
      // Selection actions belong here too. Long-press already worked on this
      // screen, so a user could enter selection mode inside a folder and find
      // no way to act on it beyond the two icons that fit in the AppBar.
      bottomNavigationBar: ref.watch(selectionProvider).isNotEmpty
          ? SelectionActionBar(
              // This screen KNOWS its list, so "select all" is scoped to the
              // folder the user is looking at rather than the whole library.
              visibleUris: videosAsync.maybeWhen(
                data: (list) => <String>[for (final v in list) v.uri],
                orElse: () => const <String>[],
              ),
            )
          : null,
      appBar: ref.watch(selectionProvider).isNotEmpty
          ? SelectionAppBar(
              totalVisible: videosAsync.maybeWhen(
                data: (list) => list.length,
                orElse: () => 0,
              ),
            )
          : _searchActive
          ? (SearchAppBar(
              onClose: () => setState(() => _searchActive = false),
            ) as PreferredSizeWidget)
          : AppBar(
              backgroundColor: AppColors.darkBackground,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              title: Text(widget.folderName),
              actions: [
                // Phase 28: 3-action bar parity with Local screen.
                // The "All folders" icon mirrors MX Player's back-to-root
                // shortcut — equivalent to tapping back. Phase 40: removed
                // the confusing snackbar; just pop straight to the folder list.
                IconButton(
                  icon: const Icon(Icons.folder_copy_outlined),
                  tooltip: 'Back to All folders',
                  onPressed: () => Navigator.of(context).pop(),
                ),
                IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.search),
                  onPressed: () => setState(() => _searchActive = true),
                ),
                IconButton(
                  tooltip: 'Layout',
                  // Phase 16: Layout-grid icon (MX Player parity)
                  icon: const Icon(Icons.dashboard_outlined),
                  onPressed: _showSortSheet,
                ),
              ],
            ),
      body: videosAsync.whenOrFallback(
        data: (videos) {
          if (videos.isEmpty) {
            final query = ref.read(searchQueryProvider);
            return Center(
              child: Text(
                query.isNotEmpty
                    ? 'No videos match "$query"'
                    : 'No videos in this folder',
                style: const TextStyle(color: AppColors.darkOnSurfaceMuted),
              ),
            );
          }

          final now = DateTime.now();
          final prefs = ref.watch(libraryPreferencesProvider);
          // Phase 45 (audit): "NEW" badge respects the user's
          // configured period (default 7 days, MX Player parity).
          final newPeriodDays = ref
              .watch(extraSettingsProvider)
              .getInt(IntSetting.newTaggedPeriod);
          final playedUris = ref.watch(playedUrisProvider);
          Widget body;
          if (prefs.layout == LayoutMode.grid) {
            body = GridView.builder(
              key: _scrollKey,
              // innocent_videos_grid_spec: 16 dp margins, 18 dp gutter,
              // 16:9 thumbs → 2 columns at 360 dp, more on larger screens.
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisSpacing: 0,
                crossAxisSpacing: 18,
                childAspectRatio: 1.13,
              ),
              itemCount: videos.length,
              itemBuilder: (_, i) {
                final video = videos[i];
                final isNew = NewBadge.applies(
                  video: video,
                  periodDays: newPeriodDays,
                  playedUris: playedUris,
                  normalize: normalizeMediaUri,
                  now: now,
                );
                return VideoGridTile(
              key: ValueKey(video.uri),
                  video: video,
                  showNewBadge: isNew,
                  onTap: () => _openVideo(video),
                  onMoreTap: () => VideoOptionMenu.show(context, video),
                  onLongPress: () =>
                      ref.read(selectionProvider.notifier).toggle(video.uri),
                );
              },
            );
          } else {
            body = ListView.builder(
              key: _scrollKey,
              itemCount: videos.length,
              itemBuilder: (context, i) {
                final video = videos[i];
                final isNew = NewBadge.applies(
                  video: video,
                  periodDays: newPeriodDays,
                  playedUris: playedUris,
                  normalize: normalizeMediaUri,
                  now: now,
                );
                return VideoListItem(
              key: ValueKey(video.uri),
                  video: video,
                  showNewBadge: isNew,
                  onTap: () => _openVideo(video),
                  onMoreTap: () => VideoOptionMenu.show(context, video),
                  onLongPress: () =>
                      ref.read(selectionProvider.notifier).toggle(video.uri),
                );
              },
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(videosInFolderProvider(widget.folderPath));
              await ref.read(videosInFolderProvider(widget.folderPath).future);
            },
            child: body,
          );
        },
        loading: () => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(AppStrings.of(context).loadingVideos,
                style: const TextStyle(
                  color: AppColors.darkOnSurfaceMuted,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(AppStrings.of(context).errorLoadingVideosPrefix + ': $e',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.error),
            ),
          ),
        ),
      ),
      ),
    );
  }
}
