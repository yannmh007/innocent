import 'access.dart';
import 'content_category.dart';
import 'viewer.dart';
import 'content_filters.dart';
import 'video_content.dart';

/// The single seam between the Video Hub UI and whatever is behind it.
///
/// EVERYTHING the screens need is on this interface, and nothing on it names a
/// storage provider. That is deliberate and is the most important design
/// decision in this feature:
///
///   • Today the implementation can be a bundled mock (no backend at all).
///   • Tomorrow it can call an API that fronts Telegram.
///   • Later it can front Bunny, Storj, or two of them with failover.
///
/// In every one of those cases the widgets are untouched, because a widget
/// never learns where a file lives — it holds a [MediaRef] and asks
/// [requestPlayback] to make it playable. Provider selection, health checks
/// and failover all live behind this line.
///
/// Implementations must not throw for "nothing found": return an empty page.
/// Throwing is reserved for real failures (no network, backend down) so the
/// UI can tell "no results" apart from "something broke" — showing a retry
/// button for an empty search is as wrong as showing "no results" for an
/// outage.
abstract class ContentRepository {
  /// The single title to feature at the top of the landing tab.
  ///
  /// A repository call rather than "row[0].items[0]" picked in the UI: what
  /// deserves the hero is an editorial decision that belongs with the content,
  /// and a real backend will want to set it explicitly rather than have the
  /// app infer it from whatever sorted highest today.
  ///
  /// Null is a valid answer (empty catalogue) and simply hides the hero.
  Future<VideoContent?> getFeatured();

  /// Curated rows for the landing ("All") tab.
  Future<List<ContentRow>> getRows();

  /// One category's catalogue, filtered and paged.
  /// [categoryId] is the STRING id and not a [ContentCategory], because the set
  /// of categories is `public.categories` and not an enum this build compiled —
  /// see [CategoryRef]. Passing an enum here is what made a new category
  /// unqueryable by a shipped app.
  Future<ContentPage> getCatalogue({
    required String categoryId,
    ContentFilters filters = const ContentFilters(),
    int page = 0,
    int pageSize = 30,
  });

  /// Which filter values this category can actually offer.
  Future<ContentFacets> getFacets({required String categoryId});

  /// What the server calls each category, in what order, and which to hide.
  ///
  /// A REPOSITORY CALL RATHER THAN A CONSTANT, for the same reason
  /// [getFeatured] is: how a catalogue names its own sections is an editorial
  /// decision that belongs with the content, not in a build. Renaming
  /// "Movies" to "Video" should not need an APK.
  ///
  /// Returning [CategoryCatalogue.empty] is CORRECT, not a failure — it means
  /// "no opinion", and every caller then uses the compiled enum and the
  /// compiled strings. That is what the demo repository returns, what a build
  /// with no backend uses, and what the app falls back to offline.
  Future<CategoryCatalogue> getCategories();

  /// The FULL list behind one of the landing rows, filtered, sorted and paged.
  ///
  /// A row shows a sample; this is what "See all" opens. It is a separate call
  /// from [getCatalogue] because a row's scope is not a category — "Trending"
  /// spans films, series and clips at once, which no single category can
  /// express.
  Future<ContentPage> getRowCatalogue({
    required String rowKey,
    ContentFilters filters = const ContentFilters(),
    int page = 0,
    int pageSize = 30,
  });

  /// Filter values available within one row's scope.
  Future<ContentFacets> getRowFacets({required String rowKey});

  /// Free-text search across the WHOLE catalogue — every category the caller
  /// is allowed to see, not just the one currently on screen.
  Future<List<VideoContent>> search(String query);

  Future<VideoContent?> getById(String id);

  /// Records that someone opened this title.
  ///
  /// WHAT COUNTS AS A VIEW, stated once so the number means something: the
  /// detail screen being opened, by anyone, free or premium. Not a scroll
  /// past the card. Not a second look a moment later - the caller de-dupes
  /// per app session, and the server should de-dupe per account per day.
  ///
  /// Every platform defines this differently and the definition is what makes
  /// the number comparable or meaningless; an undefined counter that fires on
  /// every rebuild is a random number with an eye icon next to it.
  ///
  /// FIRE-AND-FORGET. It must never block opening a title, and a failure must
  /// never surface: a lost count is worth nothing next to a screen that would
  /// not open.
  ///
  /// [tier] is carried so views can be segmented by WHO watched - anonymous,
  /// registered, paying. A single undifferentiated total cannot answer the one
  /// question that matters commercially: whether the people who never pay are
  /// the ones driving the numbers.
  Future<void> recordView(String contentId, {ViewerTier? tier});

  /// Ask for a playable URL, and be told WHY if the answer is no.
  ///
  /// THE ENFORCEMENT POINT. The UI draws locks from AccessPolicy, but a
  /// client-side check protects nothing - anyone can patch a boolean. What
  /// actually protects paid content is that this call REFUSES TO RETURN A URL,
  /// and in the API adapter that refusal is made by the SERVER against a
  /// session token the client cannot forge.
  ///
  /// Keeping the decision here rather than in the widgets is what makes that
  /// migration free: the screens already handle AccessDenial.needsPremium by
  /// showing a paywall, and they keep doing so when the verdict starts
  /// arriving over the network instead of from a local flag.
  /// [deviceId] identifies the INSTALL, so the server can bind the grant and
  /// count concurrent streams. It is advisory data, never a claim of
  /// entitlement: the client says which device it is, never whether it is
  /// allowed. Anything the client asserts about its own rights is ignored.
  Future<PlaybackGrant> requestPlayback({
    required VideoContent content,
    required MediaRef source,
    String? deviceId,
  });

  /// Same, for still images (posters and album thumbnails). Separate from
  /// [requestPlayback] because thumbnails are fetched in bulk while a stream
  /// is fetched one at a time — they will not always share a provider or a
  /// caching policy.
  Future<String?> resolveImageUrl(MediaRef ref);

  /// The answer to [resolveImageUrl] when it needs no I/O, or null when it
  /// genuinely does.
  ///
  /// Exists because artwork is drawn inside a build. A `FutureBuilder` built
  /// there gets a NEW future on every rebuild, and a fresh future always
  /// starts in the waiting state — so every poster on screen flashed its
  /// placeholder for a frame each time the grid scrolled or a filter changed.
  /// For every implementation so far the URL is already in hand (it arrived
  /// with the catalogue row), so answering synchronously removes the flash
  /// entirely.
  ///
  /// Return an EMPTY STRING for "resolved, and there is no artwork" — that is
  /// different from null, which means "ask the async one". A signing or
  /// lookup-based implementation returns null and keeps the future path.
  String? resolveImageUrlSync(MediaRef ref);
}
