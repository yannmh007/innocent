import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import '../../domain/content_filters.dart';
import '../video_hub_theme.dart';
import 'sort_sheet.dart';

/// The single toolbar above a catalogue grid.
///
/// Layout: result count on the left, Sort and Filters on the right. Both
/// buttons state their CURRENT value rather than their name alone — "Newest",
/// "Filters 2" — so the toolbar answers "what am I looking at?" without being
/// opened. A control that only shows its own name makes the user tap it to
/// find out what it is doing.
///
/// The count is on the left because it is the answer, not a control: it moves
/// when the filters move, and putting it beside them makes cause and effect
/// visible in one glance.
class FilterToolbar extends StatelessWidget {
  final ContentFilters filters;
  final int? resultCount;
  final VoidCallback onOpenFilters;
  final ValueChanged<ContentSort> onSortChanged;

  const FilterToolbar({
    super.key,
    required this.filters,
    required this.resultCount,
    required this.onOpenFilters,
    required this.onSortChanged,
  });

  static const double height = VH.toolbarHeight;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final count = resultCount;

    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VH.gutter),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                count == null ? '' : s.vhTitlesCount(count),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: VH.meta.copyWith(fontSize: 12),
              ),
            ),
            _ToolbarButton(
              icon: Icons.swap_vert_rounded,
              label: SortSheet.labelFor(s, filters.sort),
              onTap: () async {
                final picked = await SortSheet.show(
                  context,
                  current: filters.sort,
                );
                if (picked != null) onSortChanged(picked);
              },
            ),
            const SizedBox(width: VH.s2),
            _ToolbarButton(
              icon: Icons.tune_rounded,
              label: s.vhFilters,
              // The researched detail that matters most on mobile: a count on
              // the Filters button tells the user their results are narrowed
              // before they open anything.
              badge: filters.activeCount,
              highlighted: filters.activeCount > 0,
              onTap: onOpenFilters,
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int badge;
  final bool highlighted;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge = 0,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color fg = highlighted ? VH.textInverse : VH.textPrimary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VH.rPill),
      child: Container(
        height: VH.controlHeight,
        padding: const EdgeInsets.symmetric(horizontal: VH.s3),
        decoration: BoxDecoration(
          color: highlighted ? VH.textPrimary : VH.surface1,
          borderRadius: BorderRadius.circular(VH.rPill),
          border: Border.all(
            color: highlighted ? Colors.transparent : VH.hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 5),
            Text(
              label,
              style: VH.label.copyWith(color: fg, fontSize: 12.5),
            ),
            if (badge > 0) ...<Widget>[
              const SizedBox(width: 5),
              Container(
                constraints: const BoxConstraints(minWidth: 16),
                height: 16,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: VH.textInverse.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(VH.rPill),
                ),
                child: Text(
                  '$badge',
                  style: VH.badge.copyWith(color: fg, letterSpacing: 0),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The applied filters, as individually removable chips above the grid.
///
/// Kept OUTSIDE the sheet deliberately. Filters hidden behind a button are
/// filters the user forgets they set, then reads the thin results as "this app
/// has nothing" — so what is applied has to be visible without opening
/// anything.
///
/// Each chip is labelled with its facet ("Year: 2024", not "2024"): the same
/// word can appear in two facets, and a bare value leaves the user guessing
/// which one they are about to remove.
class ActiveFilterChips extends StatelessWidget {
  final ContentFilters filters;
  final ValueChanged<ContentFilters> onChanged;

  const ActiveFilterChips({
    super.key,
    required this.filters,
    required this.onChanged,
  });

  static const double height = 44;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    if (filters.isEmpty) return const SizedBox.shrink();

    final chips = <Widget>[
      for (final g in filters.genres)
        _Chip(
          label: '${s.vhFilterGenre}: $g',
          onRemove: () => onChanged(filters.toggleGenre(g)),
        ),
      if (filters.year != null)
        _Chip(
          label: '${s.vhFilterYear}: ${filters.year}',
          onRemove: () => onChanged(filters.copyWith(clearYear: true)),
        ),
      if (filters.quality != null)
        _Chip(
          label: '${s.vhFilterQuality}: ${filters.quality}',
          onRemove: () => onChanged(filters.copyWith(clearQuality: true)),
        ),
    ];

    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(VH.gutter, 0, VH.gutter, VH.s2),
        itemCount: chips.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: VH.s2),
        itemBuilder: (context, i) {
          if (i < chips.length) return chips[i];
          return _ClearAll(onTap: () => onChanged(filters.cleared()));
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;

  const _Chip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: VH.chipHeight,
      padding: const EdgeInsets.only(left: VH.s3),
      decoration: BoxDecoration(
        color: VH.surface1,
        borderRadius: BorderRadius.circular(VH.rPill),
        border: Border.all(color: VH.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: VH.label.copyWith(color: VH.textPrimary, fontSize: 12.5),
          ),
          // A 32dp square around a 12dp glyph. The research is blunt about
          // this: a small X on mobile causes mis-taps, and a mis-tap here
          // silently removes a filter the user wanted.
          InkWell(
            onTap: onRemove,
            customBorder: const CircleBorder(),
            child: const SizedBox(
              width: 32,
              height: VH.chipHeight,
              child: Icon(Icons.close_rounded,
                  size: 14, color: VH.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClearAll extends StatelessWidget {
  final VoidCallback onTap;

  const _ClearAll({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VH.rPill),
      child: Container(
        height: VH.chipHeight,
        padding: const EdgeInsets.symmetric(horizontal: VH.s3),
        alignment: Alignment.center,
        child: Text(
          s.vhClearAll,
          style: VH.label.copyWith(color: VH.textSecondary, fontSize: 12.5),
        ),
      ),
    );
  }
}
