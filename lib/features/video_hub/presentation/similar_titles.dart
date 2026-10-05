import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../data/api/api_content_repository.dart';
import '../data/api/backend_config.dart';
import '../domain/content_filters.dart';
import '../domain/video_content.dart';
import 'account_provider.dart';
import 'content_list_screen.dart';
import 'video_hub_provider.dart';
import 'widgets/content_row_view.dart';

/// "More like this" for a title: `similar_titles()` on the server
/// (migration 039 — genre, category and keyword overlap plus co-watching).
///
/// Its own provider, not a ContentRepository method: it is a server-side
/// ranking with nothing to fake in a test double, and the demo catalogue
/// answers it from the same category.
final similarTitlesProvider = FutureProvider.autoDispose
    .family<List<VideoContent>, String>((ref, titleId) async {
  if (!BackendConfig.isConfigured) {
    final rows = await ref.watch(contentRowsProvider.future);
    final all = <String, VideoContent>{
      for (final r in rows)
        for (final c in r.items) c.id: c,
    };
    final me = all[titleId];
    if (me == null) return const <VideoContent>[];
    return all.values
        .where((c) => c.id != titleId && c.category == me.category)
        .take(12)
        .toList();
  }
  final body = await ref.read(apiClientProvider).postJson(
    '/rest/v1/rpc/similar_titles',
    body: <String, dynamic>{'p_title': titleId, 'p_limit': 12},
  );
  if (body is! List) return const <VideoContent>[];
  return <VideoContent>[
    for (final m in body.whereType<Map<String, dynamic>>())
      ApiContentRepository.titleFromJson(m),
  ];
});

/// The row at the foot of a title's page. Draws nothing while loading, on
/// failure (offline) and when there is nothing similar: an empty heading is
/// worse than none.
class MoreLikeThis extends ConsumerWidget {
  const MoreLikeThis({
    super.key,
    required this.content,
    required this.onOpen,
    this.isPremiumFor,
  });

  final VideoContent content;
  final void Function(VideoContent) onOpen;
  final bool Function(VideoContent)? isPremiumFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final items = ref.watch(similarTitlesProvider(content.id)).valueOrNull;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
    // The server's "See all" for this list is the same ranking, longer: the
    // `because:<id>` row of row_catalogue().
    final row = ContentRow(
      key: 'because:${content.id}',
      fallbackTitle: s.vhMoreLikeThis,
      items: items,
      defaultSort: ContentSort.popular,
    );
    return ContentRowView(
      row: row,
      title: s.vhMoreLikeThis,
      onItemTap: onOpen,
      isPremiumFor: isPremiumFor,
      onSeeAll: (r, title) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ContentListScreen(
            rowKey: r.key,
            title: title,
            initialSort: r.defaultSort,
          ),
        ),
      ),
    );
  }
}
