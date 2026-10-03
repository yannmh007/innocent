import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../domain/video_content.dart';
import 'account/sign_in_sheet.dart';
import 'account_provider.dart';
import 'bookmarks_provider.dart';
import 'content_detail_screen.dart';
import 'video_hub_provider.dart';
import 'video_hub_theme.dart';
import 'widgets/hub_states.dart';
import 'widgets/poster_card.dart';
import 'widgets/poster_metrics.dart';
import 'widgets/vh_insets.dart';

/// The Bookmarks shelf: the titles the viewer saved, newest first.
///
/// A grid of the same poster cards as the catalogue — a saved title should
/// look exactly like the title it is — each with a filled bookmark in its
/// corner that takes it off the shelf, with Undo. Pull to refresh syncs with
/// the server when signed in.
class BookmarksScreen extends ConsumerStatefulWidget {
  const BookmarksScreen({super.key});

  @override
  ConsumerState<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends ConsumerState<BookmarksScreen> {
  /// EDIT MODE, the way iOS and Netflix's My List do it. A remove button on
  /// every card all the time sat on top of the card's own VIP badge and made
  /// a shelf of posters look like a form; it appears when asked for — the
  /// Edit button, or a long press on any card.
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final ledger = ref.watch(titleBookmarksProvider);
    final titles = ref.watch(bookmarkedTitlesProvider);
    final signedIn = ref.watch(accountProvider.select((a) => a.isSignedIn));
    final policy = ref.watch(accessPolicyProvider);
    final tier = ref.watch(viewerProvider).tier;

    return Scaffold(
      backgroundColor: VH.canvas,
      appBar: AppBar(
        backgroundColor: VH.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: VH.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: <Widget>[
          if (ledger.length > 0)
            TextButton(
              key: const ValueKey('bookmarks-edit'),
              onPressed: () => setState(() => _editing = !_editing),
              style: TextButton.styleFrom(foregroundColor: VH.textPrimary),
              child: Text(_editing ? s.done : s.vhEdit,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          const SizedBox(width: VH.s1),
        ],
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(s.vhLibraryBookmarks, style: VH.heading),
            if (ledger.length > 0)
              Text(s.vhBookmarksCount(ledger.length),
                  style: VH.meta.copyWith(fontSize: 11.5)),
          ],
        ),
      ),
      body: RefreshIndicator(
        backgroundColor: VH.surface2,
        color: VH.textPrimary,
        onRefresh: () async {
          await ref.read(titleBookmarksProvider.notifier).sync();
          ref.invalidate(bookmarkedTitlesProvider);
        },
        child: LayoutBuilder(
          builder: (context, box) => CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              if (!signedIn && ledger.length > 0)
                SliverToBoxAdapter(child: _SignInNudge(text: s.vhBookmarksSignInHint)),
              if (ledger.length == 0)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _Empty(signedIn: signedIn),
                )
              else
                ...titles.when(
                  loading: () => <Widget>[
                    const SliverToBoxAdapter(child: PosterSkeletonGrid()),
                  ],
                  error: (e, __) => <Widget>[
                    SliverToBoxAdapter(
                      child: HubErrorState(
                        error: e,
                        onRetry: () => ref.invalidate(bookmarkedTitlesProvider),
                      ),
                    ),
                  ],
                  data: (list) => <Widget>[
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                          PosterMetrics.gridPadding,
                          VH.s2,
                          PosterMetrics.gridPadding,
                          VhInsets.scrollBottom(context)),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: PosterMetrics.gridColumns,
                          crossAxisSpacing: PosterMetrics.gridSpacing,
                          mainAxisSpacing: 14,
                          mainAxisExtent:
                              PosterMetrics.gridExtent(context, box.maxWidth),
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) => _SavedCard(
                            content: list[i],
                            // The VIP corner yields to the remove button
                            // while editing; the two shared one corner.
                            premium: !_editing &&
                                policy.showsPremiumBadge(list[i], tier),
                            editing: _editing,
                            onLongPress: () => setState(() => _editing = true),
                          ),
                          childCount: list.length,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedCard extends ConsumerWidget {
  const _SavedCard({
    required this.content,
    required this.premium,
    required this.editing,
    required this.onLongPress,
  });
  final VideoContent content;
  final bool premium;
  final bool editing;
  final VoidCallback onLongPress;

  void _remove(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    HapticFeedback.selectionClick();
    final entry = ref.read(titleBookmarksProvider.notifier).remove(content.id);
    if (entry == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(s.vhBookmarkRemoved),
        action: SnackBarAction(
          label: s.vhUndo,
          onPressed: () => ref.read(titleBookmarksProvider.notifier).restore(entry),
        ),
      ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onLongPress: editing
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onLongPress();
            },
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: AnimatedScale(
              duration: VH.fast,
              scale: editing ? 0.94 : 1,
              child: PosterCard(
                content: content,
                premium: premium,
                onTap: editing
                    ? () => _remove(context, ref)
                    : () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ContentDetailScreen(content: content))),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: AnimatedScale(
              duration: VH.fast,
              scale: editing ? 1 : 0,
              child: Material(
                color: const Color(0xFFE5484D),
                shape: const CircleBorder(
                    side: BorderSide(color: VH.canvas, width: 2)),
                child: InkWell(
                  key: ValueKey('bookmark-remove-${content.id}'),
                  customBorder: const CircleBorder(),
                  onTap: editing ? () => _remove(context, ref) : null,
                  child: const Padding(
                    padding: EdgeInsets.all(5),
                    child: Icon(Icons.remove_rounded, size: 16, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.signedIn});
  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(VH.s6, VH.s6, VH.s6, VH.s6 * 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Container(
            width: 84,
            height: 84,
            decoration: const BoxDecoration(color: VH.surface1, shape: BoxShape.circle),
            child: const Icon(Icons.bookmark_add_outlined, size: 38, color: VH.textSecondary),
          ),
          const SizedBox(height: VH.s5),
          Text(s.vhBookmarksEmpty,
              textAlign: TextAlign.center,
              style: VH.body.copyWith(color: VH.textSecondary, height: 1.5)),
          if (!signedIn) ...<Widget>[
            const SizedBox(height: VH.s4),
            Text(s.vhBookmarksSignInHint,
                textAlign: TextAlign.center,
                style: VH.meta.copyWith(fontSize: 12, height: 1.45)),
            const SizedBox(height: VH.s3),
            OutlinedButton(
              onPressed: () => SignInSheet.show(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: VH.textPrimary,
                side: const BorderSide(color: VH.surface3),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(VH.rControl)),
              ),
              child: Text(s.vhSignInTitle),
            ),
          ],
        ],
      ),
    );
  }
}

class _SignInNudge extends StatelessWidget {
  const _SignInNudge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(VH.gutter, VH.s1, VH.gutter, VH.s2),
      child: Material(
        color: VH.surface1,
        borderRadius: BorderRadius.circular(VH.rControl),
        child: InkWell(
          borderRadius: BorderRadius.circular(VH.rControl),
          onTap: () => SignInSheet.show(context),
          child: Padding(
            padding: const EdgeInsets.all(VH.s3),
            child: Row(
              children: <Widget>[
                const Icon(Icons.cloud_sync_outlined, size: 19, color: VH.textSecondary),
                const SizedBox(width: VH.s3),
                Expanded(child: Text(text, style: VH.meta.copyWith(fontSize: 12, height: 1.35))),
                const Icon(Icons.chevron_right_rounded, color: VH.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
