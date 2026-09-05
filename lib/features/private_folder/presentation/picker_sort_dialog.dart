import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/localization/app_strings.dart';

/// Sort field available in the picker. Deliberately smaller than the video
/// library's SortBy — the picker mixes images, audio, APKs and arbitrary
/// files, so only universally-meaningful keys are offered.
enum PickerSort { name, date, size }

/// Row vs grid. Grid only makes sense for image-heavy views but the toggle
/// is offered everywhere for consistency (audio/files simply render a
/// denser list in "grid").
enum PickerLayout { list, grid }

enum PickerDir { asc, desc }

/// Immutable snapshot of the picker's sort/layout choice.
class PickerViewPrefs {
  final PickerSort sort;
  final PickerDir dir;
  final PickerLayout layout;
  const PickerViewPrefs({
    this.sort = PickerSort.date,
    this.dir = PickerDir.desc,
    this.layout = PickerLayout.list,
  });

  PickerViewPrefs copyWith({
    PickerSort? sort,
    PickerDir? dir,
    PickerLayout? layout,
  }) =>
      PickerViewPrefs(
        sort: sort ?? this.sort,
        dir: dir ?? this.dir,
        layout: layout ?? this.layout,
      );
}

/// Centered Sort & Layout dialog. Mirrors the Local tab's dialog styling
/// (dark card, accent chips, dynamic direction labels) but with only the
/// options that apply to a mixed-content picker. Returns the chosen prefs,
/// or null if cancelled.
class PickerSortDialog extends StatefulWidget {
  final PickerViewPrefs initial;

  /// Grid layout is only offered when the current view can show thumbnails
  /// (images/videos). For audio/files/apps the layout row is hidden.
  final bool allowGrid;

  const PickerSortDialog({
    super.key,
    required this.initial,
    this.allowGrid = true,
  });

  static Future<PickerViewPrefs?> show(
    BuildContext context,
    PickerViewPrefs initial, {
    bool allowGrid = true,
  }) {
    return showDialog<PickerViewPrefs>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) =>
          PickerSortDialog(initial: initial, allowGrid: allowGrid),
    );
  }

  @override
  State<PickerSortDialog> createState() => _PickerSortDialogState();
}

class _PickerSortDialogState extends State<PickerSortDialog> {
  late PickerViewPrefs _draft = widget.initial;

  // Sensible default direction per field (newest/largest first for
  // date/size; A→Z for name), matching the Local dialog's behaviour.
  PickerDir _defaultDir(PickerSort s) {
    switch (s) {
      case PickerSort.name:
        return PickerDir.asc;
      case PickerSort.date:
      case PickerSort.size:
        return PickerDir.desc;
    }
  }

  String _dirLabel(PickerDir d) {
    final asc = d == PickerDir.asc;
    switch (_draft.sort) {
      case PickerSort.name:
        return asc ? 'A to Z' : 'Z to A';
      case PickerSort.date:
        return asc ? 'Oldest' : 'Newest';
      case PickerSort.size:
        return asc ? 'Smallest' : 'Largest';
    }
  }

  IconData _sortIcon(PickerSort s) {
    switch (s) {
      case PickerSort.name:
        return Icons.sort_by_alpha;
      case PickerSort.date:
        return Icons.calendar_today;
      case PickerSort.size:
        return Icons.sd_card_outlined;
    }
  }

  String _sortLabel(AppStrings s, PickerSort v) {
    switch (v) {
      case PickerSort.name:
        return s.sortName;
      case PickerSort.date:
        return s.sortDate;
      case PickerSort.size:
        return s.sortSize;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Dialog(
      backgroundColor: AppColors.darkSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 60),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.allowGrid) ...[
                      _label(s.layoutSection),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          for (final l in PickerLayout.values)
                            Expanded(
                              child: _chip(
                                icon: l == PickerLayout.list
                                    ? Icons.view_list
                                    : Icons.grid_view,
                                label: l == PickerLayout.list
                                    ? s.layoutList
                                    : s.layoutGrid,
                                selected: _draft.layout == l,
                                onTap: () => setState(
                                    () => _draft = _draft.copyWith(layout: l)),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                    _label(s.sortBy),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        for (final v in PickerSort.values)
                          Expanded(
                            child: _chip(
                              icon: _sortIcon(v),
                              label: _sortLabel(s, v),
                              selected: _draft.sort == v,
                              onTap: () => setState(() => _draft =
                                  _draft.copyWith(
                                      sort: v, dir: _defaultDir(v))),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: PickerDir.values.map((d) {
                        final selected = _draft.dir == d;
                        return Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            child: InkWell(
                              onTap: () => setState(
                                  () => _draft = _draft.copyWith(dir: d)),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                height: 38,
                                decoration: BoxDecoration(
                                  color: selected
                                      ? AppColors.accentBlue.withOpacity(0.18)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: selected
                                        ? AppColors.accentBlue
                                        : Colors.white24,
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      d == PickerDir.asc
                                          ? Icons.arrow_upward
                                          : Icons.arrow_downward,
                                      size: 14,
                                      color: selected
                                          ? AppColors.accentBlue
                                          : Colors.white70,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _dirLabel(d),
                                      style: TextStyle(
                                        color: selected
                                            ? AppColors.accentBlue
                                            : Colors.white70,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(s.cancel,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5)),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_draft),
                    child: Text(s.done,
                        style: const TextStyle(
                            color: AppColors.accentBlue,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(
          color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500));

  Widget _chip({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: selected ? AppColors.accentBlue : Colors.white70,
                size: 22),
            const SizedBox(height: 6),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? AppColors.accentBlue : Colors.white70,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                )),
          ],
        ),
      ),
    );
  }
}
