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

  /// Categories offered in the bar.
  static List<ContentCategory> visible() => ContentCategory.values;
}
