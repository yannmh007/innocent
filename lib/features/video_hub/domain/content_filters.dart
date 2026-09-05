/// How a filtered grid is ordered.
///
/// `rating` was removed when star ratings left the UI. An option that sorts by
/// a number the user cannot see anywhere is a control they cannot predict, and
/// one unpredictable control makes the whole filter bar feel untrustworthy.
enum ContentSort { popular, newest, titleAsc }

extension ContentSortX on ContentSort {
  String get id {
    switch (this) {
      case ContentSort.popular:
        return 'popular';
      case ContentSort.newest:
        return 'newest';
      case ContentSort.titleAsc:
        return 'title';
    }
  }

  String get fallbackLabel {
    switch (this) {
      case ContentSort.popular:
        return 'Most watched';
      case ContentSort.newest:
        return 'Newest';
      case ContentSort.titleAsc:
        return 'A-Z';
    }
  }
}

/// Secondary filters applied within a chosen category.
///
/// Deliberately a value object with [copyWith]: the provider holds one of
/// these, and every filter control produces a NEW one. That keeps "which
/// filters are on" in exactly one place — the split-brain settings bug this
/// project has already paid for once came from the same value living in two.
class ContentFilters {
  /// Empty means "any genre". Multiple genres are OR-ed, which is what users
  /// expect from a chip row (picking Action and Comedy should widen the
  /// result set, not empty it).
  final Set<String> genres;

  final int? year;

  /// '4K' / 'HD' — matched against [VideoContent.qualityLabel].
  final String? quality;

  final ContentSort sort;

  const ContentFilters({
    this.genres = const <String>{},
    this.year,
    this.quality,
    // Most-watched, not newest. A catalogue's default ordering is a
    // recommendation, and "what everyone is watching" is a better first
    // screenful than "whatever was added last", which surfaces the thinnest
    // titles the moment a backend ingests a batch.
    this.sort = ContentSort.popular,
  });

  /// Sort is not a filter — a default sort must not make the screen claim
  /// filters are active, or the "Clear" affordance appears with nothing to
  /// clear.
  int get activeCount =>
      genres.length + (year != null ? 1 : 0) + (quality != null ? 1 : 0);

  bool get isEmpty => activeCount == 0;

  ContentFilters copyWith({
    Set<String>? genres,
    int? year,
    String? quality,
    ContentSort? sort,
    bool clearYear = false,
    bool clearQuality = false,
  }) {
    return ContentFilters(
      genres: genres ?? this.genres,
      year: clearYear ? null : (year ?? this.year),
      quality: clearQuality ? null : (quality ?? this.quality),
      sort: sort ?? this.sort,
    );
  }

  /// Toggling a chip off must REMOVE it, not leave an empty marker behind.
  ContentFilters toggleGenre(String genre) {
    final next = Set<String>.from(genres);
    if (!next.remove(genre)) next.add(genre);
    return copyWith(genres: next);
  }

  /// Stable identity of this filter set.
  ///
  /// Used as part of a paging cache key, so it must change whenever the result
  /// set would change - genres are sorted first because {A,B} and {B,A} are
  /// the same query and must not fetch twice.
  String get signature {
    final g = genres.toList()..sort();
    return '${g.join("+")}|${year ?? ""}|${quality ?? ""}|${sort.id}';
  }

  /// Clears filters but KEEPS the sort — clearing a filter set should not
  /// silently reorder the grid under the user.
  ContentFilters cleared() => ContentFilters(sort: sort);
}

/// The filter values a catalogue can actually offer, computed from the
/// catalogue itself.
///
/// Offering a genre with zero matches is the classic dead-end filter: the user
/// picks it, gets an empty screen, and blames the app. Facets are derived from
/// real data so every option shown can return something.
class ContentFacets {
  final List<String> genres;
  final List<int> years;
  final List<String> qualities;

  const ContentFacets({
    this.genres = const <String>[],
    this.years = const <int>[],
    this.qualities = const <String>[],
  });

  static const ContentFacets empty = ContentFacets();

  bool get isEmpty =>
      genres.isEmpty && years.isEmpty && qualities.isEmpty;
}
