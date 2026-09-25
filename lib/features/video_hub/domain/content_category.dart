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

/// A category the bar can show: one this build knows about, or one the operator
/// added after it shipped.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS EXISTS, AND WHAT IT REPLACES
/// ═══════════════════════════════════════════════════════════════════════
///
/// The selection used to BE a [ContentCategory], and the note further down used
/// to say — correctly — that a brand-new category therefore needed an app
/// release: "no row the server sends can make a build draw a tab it has never
/// heard of". That was the last of three things standing in the way, and the
/// other two are gone (migration 020 made public.categories the list of valid
/// categories and taught the landing page to honour visibility).
///
/// The fix is not to abolish the enum. The enum still earns its place: `all`
/// shows curated rows rather than a grid, `series` and `reels` have their own
/// glyph, and every one of them has a compiled label so the bar can draw itself
/// with no network. What had to go is the assumption that the enum is EXHAUSTIVE.
///
/// So the identity at every boundary — the query, the analytics, the saved
/// selection — is the STRING id, which is what `titles.category` has always
/// stored. [builtIn] is present when this build happens to know more about the
/// category than its name, and absent when it does not. A tab with no built-in
/// is drawn from the server's label, filtered by its id, and behaves like every
/// other flat category.
@immutable
class CategoryRef {
  /// What `titles.category` stores. The only thing that identifies a category.
  final String id;

  /// The compiled category, when this build has one for [id].
  final ContentCategory? builtIn;

  const CategoryRef._(this.id, this.builtIn);

  factory CategoryRef.of(ContentCategory category) =>
      CategoryRef._(category.id, category);

  /// A category this build has never heard of. Perfectly ordinary.
  factory CategoryRef.serverOnly(String id) => CategoryRef._(id, null);

  /// The landing tab, and the default selection.
  static const CategoryRef all =
      CategoryRef._('all', ContentCategory.all);

  /// Resolve an id against what this build knows.
  ///
  /// An unknown id becomes a server-only ref rather than falling back to
  /// [all] — falling back is what made a new category invisible, and it would
  /// now silently reinterpret a deep link into somebody's new section as the
  /// front page.
  static CategoryRef fromId(String id) {
    for (final c in ContentCategory.values) {
      if (c.id == id) return CategoryRef.of(c);
    }
    return CategoryRef.serverOnly(id);
  }

  /// True when this tab shows curated rows rather than one flat grid.
  ///
  /// Keyed on the id and not on [builtIn], so it keeps working if `all` ever
  /// arrives as a server-only row.
  bool get showsRows => id == ContentCategory.all.id;

  /// The compiled English name, or the id when there is nothing compiled. Only
  /// for logs — the screen uses the server label or [AppStrings].
  String get fallbackLabel => builtIn?.fallbackLabel ?? id;

  @override
  bool operator ==(Object other) => other is CategoryRef && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CategoryRef($id)';
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
/// ADDING A CATEGORY NO LONGER NEEDS AN APP RELEASE, and the note that used to
/// sit here saying it did was accurate when it was written. Three things stood
/// in the way and all three are gone: `titles.category` had a CHECK constraint
/// listing four names (migration 020 made it a foreign key to this table), the
/// landing page filtered a hard-coded category name (020 made it honour
/// `is_visible`), and the client keyed its tab bar off an exhaustive enum
/// (see [CategoryRef]). An INSERT here now produces a tab.
///
/// What a build still owns is the EXTRAS: a compiled label so the bar draws
/// with no network, the curated-rows behaviour of `all`, and the series and
/// reels glyphs. A category the build has never heard of gets the server's
/// name and a flat grid, which is everything a category actually needs.
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

  /// Every tab to draw, in the order to draw them — including categories this
  /// build has never heard of.
  ///
  /// THE BLEND IS THE POINT. A built-in keeps its compiled label and its
  /// behaviour; a server-only row becomes an ordinary flat tab; and both are
  /// placed by the same `sort_order`, so an operator can drop a new section
  /// between two old ones rather than only at the end.
  List<CategoryRef> refs() {
    final builtIns = ContentCategoryX.visible();
    final placed = <_Placed>[];

    for (var i = 0; i < builtIns.length; i++) {
      final c = builtIns[i];
      final style = byId[c.id];
      // [ContentCategory.all] is NEVER hidden, whatever the row says. It is the
      // landing tab and the default selection, so hiding it would leave the hub
      // opened on a tab that is not in the bar — a state no operator would
      // expect from setting `is_visible = false`.
      if (c != ContentCategory.all && !(style?.isVisible ?? true)) continue;
      // An unknown id sorts by its enum index so it lands where it always was:
      // the server not knowing about a tab is the normal state immediately
      // after a release adds one.
      placed.add(_Placed(CategoryRef.of(c), style?.sortOrder ?? i, i));
    }

    final known = <String>{for (final c in builtIns) c.id};
    var tie = builtIns.length;
    final extras = <CategoryStyle>[
      for (final style in byId.values)
        if (!known.contains(style.id) && style.isVisible) style,
    ]..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        // Tie-broken on the id so two rows with the same sort_order do not swap
        // places between launches, which reads as the app shuffling itself.
        return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
      });
    for (final style in extras) {
      placed.add(_Placed(
          CategoryRef.serverOnly(style.id), style.sortOrder, tie++));
    }

    placed.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : a.tie.compareTo(b.tie);
    });
    return <CategoryRef>[for (final p in placed) p.ref];
  }

  /// The server's label for an id, or null when it has nothing usable to say.
  String? labelForId(String id, String? languageCode) {
    final style = byId[id];
    if (style == null) return null;
    final label = style.displayLabel(languageCode).trim();
    return label.isEmpty ? null : label;
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


/// One category and where it sits, while [CategoryCatalogue.refs] is deciding.
///
/// A plain class rather than a record, because this file is compiled at
/// language version 3.4 and a small private class reads the same and cannot be
/// wrong about it.
class _Placed {
  _Placed(this.ref, this.order, this.tie);

  final CategoryRef ref;
  final int order;

  /// Breaks a tie in [order] with the position the tab would have had anyway,
  /// so equal sort orders produce a stable, unsurprising bar.
  final int tie;
}
