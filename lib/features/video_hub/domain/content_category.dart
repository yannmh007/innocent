import 'package:flutter/material.dart';

/// Top-level content categories shown in the Video Hub's sticky category bar.
///
/// Design note (researched against Bioscope / Netflix / YouTube):
/// the top-level bar stays SHORT — five entries at most. Genre, year and
/// quality are deliberately NOT here; they are secondary filters that appear
/// once a category is chosen. A scrollable tab bar stops being scannable past
/// roughly six items, and every extra top-level tab makes the primary choice
/// harder rather than easier.
///
/// Order is index-significant: [all] must stay first (it is the landing tab).
/// Only ever APPEND.
///
/// There is no `adult` category any more, and its absence is the design: the
/// WHOLE catalogue is adult now, so a category for it would have been a tab
/// that always matched everything. The 18+ decision moved to the door - see
/// `presentation/gate/age_gate_screen.dart` - which is both where it belongs
/// and where every other adult platform puts it.
enum ContentCategory {
  all,
  movies,
  series,
  reels,
}

extension ContentCategoryX on ContentCategory {
  /// Stable identifier used in storage, analytics and the backend query.
  /// NEVER derive this from the localized label — the label changes per
  /// locale, this must not.
  String get id {
    switch (this) {
      case ContentCategory.all:
        return 'all';
      case ContentCategory.movies:
        return 'movies';
      case ContentCategory.series:
        return 'series';
      case ContentCategory.reels:
        return 'reels';
    }
  }

  /// English fallback label. The screen uses AppStrings for the visible text;
  /// this exists so a log line or a missing translation never shows a blank.
  String get fallbackLabel {
    switch (this) {
      case ContentCategory.all:
        return 'All';
      case ContentCategory.movies:
        return 'Movies';
      case ContentCategory.series:
        return 'Series';
      case ContentCategory.reels:
        return 'Reels';
    }
  }

  /// Small leading glyph shown inside the pill. Kept optional-looking (only
  /// the gated tab really needs one) so the bar reads as text, not as icons.
  IconData? get icon {
    switch (this) {
      default:
        return null;
    }
  }

  /// True when this tab shows curated rows rather than one flat grid.
  bool get showsRows => this == ContentCategory.all;

  /// Parse back from [id]; unknown ids fall back to [ContentCategory.all]
  /// rather than throwing, so a stale saved value can never break startup.
  static ContentCategory fromId(String? id) {
    for (final c in ContentCategory.values) {
      if (c.id == id) return c;
    }
    return ContentCategory.all;
  }

  /// Categories offered in the bar when the server has no opinion.
  ///
  /// The DEFAULT, not the answer. What the bar actually draws comes from
  /// [CategoryCatalogue.visible], which starts here and then applies the
  /// server's order and visibility. Kept as the single statement of "which
  /// tabs a build knows about" so that list is written once.
  static List<ContentCategory> visible() => ContentCategory.values;
}

/// One category's SERVER-CONTROLLED presentation.
///
/// The owner asked to be able to rename "Movies" to "Video" without shipping
/// an app, and confirmed the rule that makes it safe: *"id မပြောင်းလဲ ရတယ်"* —
/// only the text changes. That split is the whole design:
///
///   [ContentCategory] / [ContentCategoryX.id]
///       The IDENTITY. What `titles.category` stores, what analytics group
///       by, what a saved tab selection holds. Frozen forever — changing one
///       orphans every title that used it.
///
///   [label], [labelMm], [sortOrder], [isVisible]
///       The PRESENTATION. Owned by `public.categories` and changed with an
///       UPDATE.
///
/// WHAT THIS DELIBERATELY DOES NOT DO, stated here rather than discovered
/// later: a brand-new category still needs an app release. The client keys
/// off an enum, and no row the server sends can make a build draw a tab it
/// has never heard of. Renaming, reordering and hiding are what this buys;
/// adding is a different piece of work.
@immutable
class CategoryStyle {
  final String id;
  final String label;
  final String? labelMm;
  final int sortOrder;
  final bool isVisible;

  const CategoryStyle({
    required this.id,
    required this.label,
    this.labelMm,
    this.sortOrder = 0,
    this.isVisible = true,
  });

  /// The name to show, given the language the app is running in.
  ///
  /// Same fallback rule as [VideoContent.displayTitle]: a blank or
  /// whitespace-only `label_mm` falls back rather than rendering an empty
  /// pill, because somebody will eventually save one by accident.
  String displayLabel(String? languageCode) {
    if (languageCode != 'my') return label;
    final mm = labelMm?.trim();
    return (mm == null || mm.isEmpty) ? label : mm;
  }
}

/// What the server says about every category, and what to do when it says
/// nothing.
///
/// A VALUE OBJECT WITH PURE METHODS, so the two rules below can be tested
/// without a network, a provider or a widget — which matters because both of
/// them fail SILENTLY. A wrong order looks like a design choice; a wrongly
/// hidden tab looks like an empty catalogue.
@immutable
class CategoryCatalogue {
  final Map<String, CategoryStyle> byId;

  const CategoryCatalogue(this.byId);

  /// What every build falls back to: the compiled enum, in its own order,
  /// with the compiled strings.
  ///
  /// NOT AN ERROR STATE. It is what the app shows before the first fetch
  /// returns, what it shows when the phone is offline, and what it shows if
  /// the table is ever emptied. A catalogue that cannot draw its own tab bar
  /// without the network is worse than one with month-old labels.
  static const CategoryCatalogue empty =
      CategoryCatalogue(<String, CategoryStyle>{});

  bool get isEmpty => byId.isEmpty;

  /// The tabs to draw, in the order to draw them.
  ///
  /// [ContentCategory.all] is NEVER hidden, whatever the row says. It is the
  /// landing tab and the default of `selectedCategoryProvider`, so hiding it
  /// would leave the hub opened on a tab that is not in the bar — a state no
  /// operator would expect from setting `is_visible = false` on a row.
  ///
  /// An enum value the server has never heard of keeps its place rather than
  /// disappearing: the server not knowing about a tab is the normal state
  /// immediately after a release adds one.
  List<ContentCategory> visible() {
    final all = ContentCategoryX.visible();
    if (isEmpty) return all;

    final kept = <ContentCategory>[
      for (final c in all)
        if (c == ContentCategory.all || (byId[c.id]?.isVisible ?? true)) c,
    ];

    // Stable: equal sort orders keep enum order, and an unknown id sorts by
    // its enum index so it lands where it always was.
    final indexOf = <ContentCategory, int>{
      for (var i = 0; i < all.length; i++) all[i]: i,
    };
    kept.sort((a, b) {
      final sa = byId[a.id]?.sortOrder ?? indexOf[a]!;
      final sb = byId[b.id]?.sortOrder ?? indexOf[b]!;
      if (sa != sb) return sa.compareTo(sb);
      return indexOf[a]!.compareTo(indexOf[b]!);
    });

    // No empty-list guard, and none is reachable: [ContentCategory.all] is
    // kept unconditionally above, so the worst a table of `is_visible = false`
    // can produce is a bar showing only All — which is a legitimate thing for
    // an operator to want while a catalogue is being rebuilt.
    return kept;
  }

  /// The server's name for a category, or null to use the compiled string.
  ///
  /// NULL ONLY WHEN THE SERVER HAS NOTHING USABLE TO SAY — no row, or a row
  /// whose label for this language is blank. It is not null merely because
  /// the language has no column of its own.
  ///
  /// That last part is the case worth being explicit about. `AppStrings`
  /// carries English, Burmese and Thai; `public.categories` carries English
  /// and Burmese. When an operator renames Movies to Video, a Thai viewer
  /// gets `Video` — the English label — rather than the compiled Thai word
  /// for "Movies". That is deliberate: the compiled string is now the OLD
  /// NAME, and showing the old name to one audience is worse than showing a
  /// new one they can read. An untranslated rename is a translation gap; a
  /// stale rename is a wrong answer.
  String? labelFor(ContentCategory category, String? languageCode) {
    final style = byId[category.id];
    if (style == null) return null;
    final label = style.displayLabel(languageCode).trim();
    return label.isEmpty ? null : label;
  }
}
