import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../domain/sort_options.dart';
import 'library_provider.dart';

import '../../../core/localization/app_strings.dart';
/// Sort & View Mode — shown as centered DIALOG (PDF page 2 spec).
/// Premium look: tight spacing, fixed grid, dark surface card.
class SortViewDialog extends ConsumerStatefulWidget {
  /// Which preferences store this dialog reads and writes. Defaults to the
  /// Local tab's; the Private Folder passes its own isolated provider so
  /// changing sort/view inside the vault never leaks to the public Local
  /// tab (and vice-versa). Nullable so it can't force a non-const default
  /// into a const context; resolved to [libraryPreferencesProvider] at use.
  final StateNotifierProvider<LibraryPreferencesNotifier, LibraryPreferences>?
      preferencesProvider;

  const SortViewDialog({
    super.key,
    this.preferencesProvider,
  });

  /// The effective store — falls back to the Local tab's when none given.
  StateNotifierProvider<LibraryPreferencesNotifier, LibraryPreferences>
      get _prefsProvider => preferencesProvider ?? libraryPreferencesProvider;

  /// Show as standard Dialog (centered popup). [preferencesProvider] lets
  /// the caller target an isolated store (e.g. the Private Folder's).
  static Future<void> show(
    BuildContext context, {
    StateNotifierProvider<LibraryPreferencesNotifier, LibraryPreferences>?
        preferencesProvider,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) =>
          SortViewDialog(preferencesProvider: preferencesProvider),
    );
  }

  @override
  ConsumerState<SortViewDialog> createState() => _SortViewDialogState();
}

class _SortViewDialogState extends ConsumerState<SortViewDialog> {
  bool _fieldsExpanded = false;
  bool _advancedExpanded = false;
  late LibraryPreferences _draft;

  @override
  void initState() {
    super.initState();
    _draft = ref.read(widget._prefsProvider);
  }

  void _commit() {
    final notifier = ref.read(widget._prefsProvider.notifier);
    notifier.setSortBy(_draft.sortBy);
    notifier.setDirection(_draft.direction);
    notifier.setViewMode(_draft.viewMode);
    notifier.setLayout(_draft.layout);
    // Phase 29: persist Fields + Advanced too
    notifier.setFields(
      showThumbnail: _draft.showThumbnail,
      showLength: _draft.showLength,
      showFileExt: _draft.showFileExt,
      showPlayedTime: _draft.showPlayedTime,
      showResolution: _draft.showResolution,
      showFrameRate: _draft.showFrameRate,
      showPath: _draft.showPath,
      showSize: _draft.showSize,
      showDate: _draft.showDate,
    );
    notifier.setAdvanced(
      displayLengthOverThumb: _draft.displayLengthOverThumb,
      showHidden: _draft.showHidden,
      recognizeNomedia: _draft.recognizeNomedia,
    );
    Navigator.of(context).pop();
  }

  // Phase 30: Direction labels change with sort field (MX Player parity).
  // Verified against MX Player screen recording.
  // - Title         → A to Z / Z to A
  // - Date          → Oldest / Newest
  // - Played time   → Oldest / Newest
  // - Length        → Shortest / Longest
  // - Size          → Smallest / Largest
  // - Resolution    → Lowest / Highest
  // - Frame rate    → Lowest / Highest
  // - Status/Path/Type → Ascending / Descending
  String _directionLabel(SortDirection d) {
    final asc = d == SortDirection.oldestFirst;
    switch (_draft.sortBy) {
      case SortBy.title:
        return asc ? 'A to Z' : 'Z to A';
      case SortBy.date:
      case SortBy.playedTime:
        return asc ? 'Oldest' : 'Newest';
      case SortBy.length:
        return asc ? 'Shortest' : 'Longest';
      case SortBy.size:
        return asc ? 'Smallest' : 'Largest';
      case SortBy.resolution:
        return asc ? 'Lowest' : 'Highest';
      case SortBy.frameRate:
        return asc ? 'Lowest' : 'Highest';
      case SortBy.status:
      case SortBy.path:
      case SortBy.type:
        return asc ? 'Ascending' : 'Descending';
    }
  }

  // Phase 30: When user picks a new sort criterion, MX auto-selects a
  // sensible default direction. Verified from screen recording:
  // - Date/Length/Size/Frame rate/Played time → "biggest" first (newestFirst)
  // - Title/Status/Path/Type/Resolution        → "ascending" (oldestFirst)
  SortDirection _defaultDirectionFor(SortBy s) {
    switch (s) {
      case SortBy.date:
      case SortBy.playedTime:
      case SortBy.length:
      case SortBy.size:
      case SortBy.frameRate:
        return SortDirection.newestFirst;
      case SortBy.title:
      case SortBy.status:
      case SortBy.path:
      case SortBy.type:
      case SortBy.resolution:
        return SortDirection.oldestFirst;
    }
  }

  void _selectSortBy(SortBy s) {
    setState(() {
      _draft = _draft.copyWith(
        sortBy: s,
        direction: _defaultDirectionFor(s),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.darkSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // View Mode (left) + Layout (right) headers in same row
                    Row(
                      children: const [
                        Expanded(
                          flex: 3,
                          child: _SectionLabel('View Mode'),
                        ),
                        Expanded(
                          flex: 2,
                          child: _SectionLabel('Layout'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // View Mode chips: 3 in a row
                        Expanded(
                          flex: 3,
                          child: Row(
                            children: [
                              for (final v in ViewMode.values)
                                Expanded(
                                  child: _GridChip(
                                    icon: _viewIcon(v),
                                    label: v.label,
                                    selected: _draft.viewMode == v,
                                    onTap: () => setState(() =>
                                        _draft = _draft.copyWith(viewMode: v)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        // Vertical separator line
                        Container(
                          width: 1,
                          height: 56,
                          color: Colors.white12,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                        // Layout chips: 2 in a row
                        Expanded(
                          flex: 2,
                          child: Row(
                            children: [
                              for (final l in LayoutMode.values)
                                Expanded(
                                  child: _GridChip(
                                    icon: l == LayoutMode.list
                                        ? Icons.view_list
                                        : Icons.grid_view,
                                    label: l.label,
                                    selected: _draft.layout == l,
                                    onTap: () => setState(() =>
                                        _draft = _draft.copyWith(layout: l)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // Sort section header
                    const _SectionLabel('Sort'),
                    const SizedBox(height: 12),

                    // Sort 5-column grid (Title/Date/PlayedTime/Status/Length on row 1)
                    GridView.count(
                      crossAxisCount: 5,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      childAspectRatio: 0.78,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 4,
                      children: [
                        for (final s in SortBy.values)
                          _GridChip(
                            icon: _sortIcon(s),
                            label: s.label,
                            selected: _draft.sortBy == s,
                            onTap: () => _selectSortBy(s),
                          ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    // Direction row — labels switch dynamically based on sortBy
                    Row(
                      children: SortDirection.values.map((d) {
                        final selected = _draft.direction == d;
                        return Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            child: InkWell(
                              onTap: () => setState(() =>
                                  _draft = _draft.copyWith(direction: d)),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                height: 38,
                                decoration: BoxDecoration(
                                  color: selected
                                      ? AppColors.accentBlue
                                          .withOpacity(0.18)
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
                                      d == SortDirection.oldestFirst
                                          ? Icons.arrow_upward
                                          : Icons.arrow_downward,
                                      size: 14,
                                      color: selected
                                          ? AppColors.accentBlue
                                          : Colors.white70,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _directionLabel(d),
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

                    const SizedBox(height: 6),

                    // ─── FIELDS expandable: real 3-col checkbox grid ───
                    _Expandable(
                      title: 'Fields',
                      expanded: _fieldsExpanded,
                      onToggle: () => setState(
                          () => _fieldsExpanded = !_fieldsExpanded),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GridView.count(
                          crossAxisCount: 3,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          mainAxisSpacing: 0,
                          crossAxisSpacing: 0,
                          childAspectRatio: 3.5,
                          children: [
                            _FieldCheck(
                              label: 'Thumbnail',
                              value: _draft.showThumbnail,
                              onChanged: (v) => setState(() =>
                                  _draft = _draft.copyWith(showThumbnail: v)),
                            ),
                            _FieldCheck(
                              label: 'Length',
                              value: _draft.showLength,
                              onChanged: (v) => setState(() =>
                                  _draft = _draft.copyWith(showLength: v)),
                            ),
                            _FieldCheck(
                              label: 'File extension',
                              value: _draft.showFileExt,
                              onChanged: (v) => setState(() =>
                                  _draft = _draft.copyWith(showFileExt: v)),
                            ),
                            _FieldCheck(
                              label: 'Played time',
                              value: _draft.showPlayedTime,
                              onChanged: (v) => setState(() =>
                                  _draft = _draft.copyWith(showPlayedTime: v)),
                            ),
                            _FieldCheck(
                              label: 'Resolution',
                              value: _draft.showResolution,
                              onChanged: (v) => setState(() =>
                                  _draft = _draft.copyWith(showResolution: v)),
                            ),
                            _FieldCheck(
                              label: 'Frame rate',
                              value: _draft.showFrameRate,
                              onChanged: (v) => setState(() =>
                                  _draft = _draft.copyWith(showFrameRate: v)),
                            ),
                            _FieldCheck(
                              label: 'Path',
                              value: _draft.showPath,
                              onChanged: (v) => setState(() =>
                                  _draft = _draft.copyWith(showPath: v)),
                            ),
                            _FieldCheck(
                              label: 'Size',
                              value: _draft.showSize,
                              onChanged: (v) => setState(() =>
                                  _draft = _draft.copyWith(showSize: v)),
                            ),
                            _FieldCheck(
                              label: 'Date',
                              value: _draft.showDate,
                              onChanged: (v) => setState(() =>
                                  _draft = _draft.copyWith(showDate: v)),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white12),

                    // ─── ADVANCED expandable: real 3 switches ───
                    _Expandable(
                      title: 'Advanced',
                      expanded: _advancedExpanded,
                      onToggle: () => setState(
                          () => _advancedExpanded = !_advancedExpanded),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          children: [
                            _AdvSwitch(
                              label: 'Display length over thumbnail',
                              value: _draft.displayLengthOverThumb,
                              onChanged: (v) => setState(() => _draft =
                                  _draft.copyWith(displayLengthOverThumb: v)),
                            ),
                            _AdvSwitch(
                              label: 'Show hidden files and folders',
                              value: _draft.showHidden,
                              onChanged: (v) => setState(() =>
                                  _draft = _draft.copyWith(showHidden: v)),
                            ),
                            _AdvSwitch(
                              label: 'Recognize .nomedia',
                              value: _draft.recognizeNomedia,
                              onChanged: (v) => setState(() => _draft =
                                  _draft.copyWith(recognizeNomedia: v)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Cancel / Done footer
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                    ),
                    child: Text(AppStrings.of(context).cancel,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: _commit,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                    ),
                    child: Text(AppStrings.of(context).done,
                      style: TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _viewIcon(ViewMode v) {
    switch (v) {
      case ViewMode.allFolders:
        return Icons.folder_copy_outlined;
      case ViewMode.files:
        return Icons.description_outlined;
      case ViewMode.folders:
        return Icons.folder_outlined;
    }
  }

  IconData _sortIcon(SortBy s) {
    switch (s) {
      case SortBy.title:
        return Icons.sort_by_alpha;
      case SortBy.date:
        return Icons.calendar_today;
      case SortBy.playedTime:
        // MX shows a clock with a rotating-back-arrow style
        return Icons.history;
      case SortBy.status:
        // MX shows a circle-with-arc-and-play (resembles "in progress" indicator)
        return Icons.timelapse;
      case SortBy.length:
        return Icons.smart_display_outlined;
      case SortBy.size:
        // SD card outline (not data_usage donut)
        return Icons.sd_card_outlined;
      case SortBy.resolution:
        return Icons.hd_outlined;
      case SortBy.path:
        return Icons.add_location_alt_outlined;
      case SortBy.frameRate:
        return Icons.sixty_fps_outlined;
      case SortBy.type:
        return Icons.video_file_outlined;
    }
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 15,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _FieldCheck extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _FieldCheck({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: AppColors.accentBlue,
              checkColor: Colors.white,
              side: const BorderSide(color: Colors.white54, width: 1.4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(3),
              ),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdvSwitch extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _AdvSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: Colors.white,
            activeTrackColor: AppColors.accentBlue,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: Colors.white24,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}

class _GridChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _GridChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            color: selected ? AppColors.accentBlue : Colors.white70,
            size: 22,
          ),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? AppColors.accentBlue : Colors.white70,
                fontSize: 10,
                height: 1.15,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Expandable extends StatelessWidget {
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  const _Expandable({
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Icon(
                  expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  color: Colors.white70,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (expanded) child,
      ],
    );
  }
}
