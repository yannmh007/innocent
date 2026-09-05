import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import '../../domain/content_filters.dart';
import '../video_hub_theme.dart';

/// Sort options, presented as a bottom sheet.
///
/// Separate from the filter sheet on purpose. Filtering and sorting answer
/// different questions — "which titles?" and "in what order?" — and merging
/// them into one panel makes the user wade through genres to change an
/// ordering. They share a toolbar; they do not share a surface.
///
/// Applies IMMEDIATELY on tap, unlike the filter sheet. Sorting is one
/// decision with one visible consequence, so a confirm step would be a tap
/// spent on nothing.
class SortSheet {
  const SortSheet._();

  static Future<ContentSort?> show(
    BuildContext context, {
    required ContentSort current,
  }) {
    final s = AppStrings.of(context);
    return showModalBottomSheet<ContentSort>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: VH.surface2,
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(VH.rSheet)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: VH.s2, bottom: VH.s1),
                  child: Center(
                    child: Container(
                      width: 34,
                      height: 4,
                      decoration: BoxDecoration(
                        color: VH.textTertiary.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      VH.gutter, VH.s2, VH.gutter, VH.s2),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(s.vhFilterSort, style: VH.heading),
                  ),
                ),
                ...ContentSort.values.map((sort) {
                  final selected = sort == current;
                  return InkWell(
                    onTap: () => Navigator.of(context).pop(sort),
                    child: Container(
                      height: 52,
                      padding: const EdgeInsets.symmetric(
                          horizontal: VH.gutter),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              labelFor(s, sort),
                              style: VH.label.copyWith(
                                color: selected
                                    ? VH.textPrimary
                                    : VH.textSecondary,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                fontSize: 14.5,
                              ),
                            ),
                          ),
                          if (selected)
                            const Icon(Icons.check_rounded,
                                size: 20, color: VH.textPrimary),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: VH.s2),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Localized sort label. Single definition, used by the sheet AND by the
  /// toolbar button that displays the current choice.
  static String labelFor(AppStrings s, ContentSort sort) {
    switch (sort) {
      case ContentSort.popular:
        return s.vhSortPopular;
      case ContentSort.newest:
        return s.vhSortNewest;
      case ContentSort.titleAsc:
        return s.vhSortTitle;
    }
  }
}
