import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/api_content_repository.dart';
import '../data/api/backend_config.dart';
import '../data/demo_content_repository.dart';
import '../domain/access.dart';
import '../domain/access_policy.dart';
import '../domain/content_category.dart';
import '../domain/content_filters.dart';
import '../domain/content_repository.dart';
import 'account_provider.dart';
import '../domain/video_content.dart';

/// THE SWAP POINT.
///
/// Every screen reads the repository through this one provider. Moving the
/// Video Hub from the bundled demo catalogue to a real backend is a one-line
/// change here — return `ApiContentRepository(...)` instead — and nothing
/// above this line is edited. Overriding it in a test or a preview works the
/// same way.
final contentRepositoryProvider = Provider<ContentRepository>((ref) {
  if (!BackendConfig.isConfigured) return DemoContentRepository();
  return ApiContentRepository(ref.watch(apiClientProvider));
});

/// What the viewer currently has, DERIVED from the account.
///
/// Not its own store. Entitlement belongs to an ACCOUNT, and a second copy on
/// the device is a second thing to keep in step - the one that goes stale is
/// always the one some screen happens to read. Signing out drops both in the
/// same assignment because there is only one.
final entitlementProvider = Provider<Entitlement>((ref) {
  return ref.watch(accountProvider).entitlement;
});

/// The active free-tier rules. A provider rather than a bare const so a
/// promotion ("all titles free this weekend") becomes a config change instead
/// of a release.
final accessPolicyProvider =
    Provider<AccessPolicy>((ref) => AccessPolicy.standard);

/// The category currently selected in the sticky bar.
final selectedCategoryProvider =
    StateProvider<ContentCategory>((ref) => ContentCategory.all);

/// Secondary filters for the selected category.
///
/// Reset when the category changes: a genre that exists under Movies may not
/// exist under Reels, and carrying it across is how a user lands on an empty
/// grid with no idea why.
final contentFiltersProvider =
    StateProvider<ContentFilters>((ref) => const ContentFilters());

/// The hero title for the landing tab.
final featuredContentProvider = FutureProvider<VideoContent?>((ref) {
  final repo = ref.watch(contentRepositoryProvider);
  return repo.getFeatured();
});

/// Curated rows for the "All" tab.
final contentRowsProvider = FutureProvider<List<ContentRow>>((ref) {
  final repo = ref.watch(contentRepositoryProvider);
  return repo.getRows();
});

/// Filter values the current category can actually offer.
final categoryFacetsProvider =
    FutureProvider.autoDispose<ContentFacets>((ref) {
  final repo = ref.watch(contentRepositoryProvider);
  final category = ref.watch(selectedCategoryProvider);
  return repo.getFacets(category: category);
});

/// Identity of a row-facets request. Needs `==`/`hashCode` because it is a
/// Riverpod family argument.
@immutable
class RowFacetsArg {
  final String rowKey;

  const RowFacetsArg(this.rowKey);

  @override
  bool operator ==(Object other) =>
      other is RowFacetsArg && other.rowKey == rowKey;

  @override
  int get hashCode => rowKey.hashCode;
}

/// Filter values available inside one row's scope.
final rowFacetsProvider = FutureProvider.autoDispose
    .family<ContentFacets, RowFacetsArg>((ref, arg) {
  final repo = ref.watch(contentRepositoryProvider);
  return repo.getRowFacets(rowKey: arg.rowKey);
});

/// Titles already counted this app run.
///
/// Without it, opening a title, backing out and opening it again would count
/// twice - and a user flicking through five titles and back would add ten
/// views in a minute. The server should also de-dupe per account per day;
/// this only stops the app inflating its own numbers.
final _countedViews = <String>{};

/// Records a view, once per title per app run.
///
/// Deliberately returns void and swallows failures: opening a title must not
/// wait on a counter, and must not fail because of one.
void recordViewOnce(WidgetRef ref, String contentId) {
  if (!_countedViews.add(contentId)) return;
  final tier = ref.read(viewerProvider).tier;
  // ignore: discarded_futures
  ref
      .read(contentRepositoryProvider)
      .recordView(contentId, tier: tier)
      .catchError((_) {});
}

/// Live search query. Held in a provider rather than in the search screen's
/// State so a result tap can pop back to a screen that still shows the query.
final videoSearchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

/// Search results across every category the user may see.
final videoSearchResultsProvider =
    FutureProvider.autoDispose<List<VideoContent>>((ref) async {
  final query = ref.watch(videoSearchQueryProvider);
  if (query.trim().isEmpty) return const <VideoContent>[];
  final repo = ref.watch(contentRepositoryProvider);
  return repo.search(query);
});
