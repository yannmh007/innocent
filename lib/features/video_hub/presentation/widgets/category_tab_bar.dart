import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/localization/app_strings.dart';
import '../../domain/content_category.dart';
import '../video_hub_theme.dart';

/// The horizontally-scrolling category bar between the search field and the
/// content.
///
/// SELECTED STATE IS LUMINANCE, NOT COLOUR. The first cut filled the active
/// pill with the app's saturated blue, which is what made the screen read as
/// a toy: a bright primary rectangle is the loudest thing on a black page, and
/// it was competing with the artwork the page exists to show. On a dark canvas
/// the premium convention - Spotify, Apple, Netflix - is to raise the SELECTED
/// item to near-white and let everything else recede. Same information, no
/// shouting, and the posters stay the brightest content on screen.
class CategoryTabBar extends StatefulWidget {
  final List<CategoryRef> categories;
  final CategoryRef selected;
  final ValueChanged<CategoryRef> onSelected;

  /// What the SERVER calls these categories, where it has an opinion.
  ///
  /// Defaulted to empty so every existing call site and every test keeps
  /// compiling and keeps showing exactly what it showed before.
  final CategoryCatalogue styles;

  const CategoryTabBar({
    super.key,
    required this.categories,
    required this.selected,
    required this.onSelected,
    this.styles = CategoryCatalogue.empty,
  });

  static const double height = VH.barHeight;

  @override
  State<CategoryTabBar> createState() => _CategoryTabBarState();
}

class _CategoryTabBarState extends State<CategoryTabBar> {
  /// One key per category so the selected pill can be scrolled into view.
  /// Without this, selecting a tab that sits off-screen leaves the bar showing
  /// a selection the user cannot see.
  // Keyed on the ID, so a category this build has never heard of gets a key
  // like any other tab.
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};

  @override
  void didUpdateWidget(covariant CategoryTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _revealSelected();
    }
  }

  void _revealSelected() {
    // Deferred: during didUpdateWidget the new pill may not be laid out yet,
    // and ensureVisible on an unlaid-out box does nothing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _keys[widget.selected.id]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: VH.normal,
        curve: VH.ease,
        alignment: 0.5,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return SizedBox(
      height: CategoryTabBar.height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: VH.gutter,
          vertical: VH.s2,
        ),
        itemCount: widget.categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: VH.s2),
        itemBuilder: (context, index) {
          final category = widget.categories[index];
          final key = _keys.putIfAbsent(category.id, () => GlobalKey());
          return _CategoryPill(
            key: key,
            label: labelFor(s, category, styles: widget.styles),
            // A glyph is something only a BUILT-IN tab can have: it is a
            // compiled asset, and a category added after this build shipped has
            // no way to name one. Text-only is the right answer there, and the
            // bar was designed to read as text anyway.
            icon: category.builtIn?.icon,
            selected: category == widget.selected,
            onTap: () {
              if (category == widget.selected) return;
              HapticFeedback.selectionClick();
              widget.onSelected(category);
            },
          );
        },
      ),
    );
  }

  /// Localized label for a category. Lives here so every surface that shows a
  /// category name spells it the same way.
  ///
  /// THE SERVER WINS WHEN IT HAS SOMETHING TO SAY, and the compiled string is
  /// what is drawn when it does not. That ordering is the feature: renaming
  /// "Movies" to "Video" is one UPDATE and takes effect on the next launch.
  ///
  /// The compiled string is the fallback for "the server said nothing", NOT
  /// for "the server said nothing in this language". A rename has to reach
  /// every audience: after Movies becomes Video, a Thai viewer seeing the
  /// compiled Thai word for "Movies" is being shown the old name, which is
  /// worse than an English one they can read. See CategoryCatalogue.labelFor.
  static String labelFor(
    AppStrings s,
    CategoryRef category, {
    CategoryCatalogue styles = CategoryCatalogue.empty,
  }) {
    final fromServer = styles.labelForId(category.id, s.locale.languageCode);
    if (fromServer != null) return fromServer;
    // A category this build has never heard of has no compiled string to fall
    // back to, and its id is the only name anything here knows. It should never
    // be reached — a server-only tab exists BECAUSE the server sent a row for
    // it, and that row is what `labelForId` reads — but an id on screen beats
    // an empty pill, which reads as a rendering bug.
    final builtIn = category.builtIn;
    if (builtIn == null) return category.id;
    switch (builtIn) {
      case ContentCategory.all:
        return s.vhCategoryAll;
      case ContentCategory.movies:
        return s.vhCategoryMovies;
      case ContentCategory.series:
        return s.vhCategorySeries;
      case ContentCategory.reels:
        return s.vhCategoryReels;
    }
  }
}

class _CategoryPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final Color fg = selected ? VH.textInverse : VH.textSecondary;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(VH.rPill),
        child: AnimatedContainer(
          duration: VH.fast,
          curve: VH.ease,
          padding: const EdgeInsets.symmetric(horizontal: VH.s3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? VH.textPrimary : Colors.transparent,
            borderRadius: BorderRadius.circular(VH.rPill),
            // Unselected pills are outlined, not filled: on a black page a
            // filled dark chip and the page itself are nearly the same tone,
            // so the row loses its shape entirely.
            border: Border.all(
              color: selected ? Colors.transparent : VH.hairline,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 13, color: fg),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: VH.label.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
