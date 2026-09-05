import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/localization/app_strings.dart';
import '../../domain/content_filters.dart';
import '../video_hub_theme.dart';

/// The filter panel, presented as a bottom sheet.
///
/// This replaced a row of four dropdown pills sitting permanently under the
/// category bar. That row cost 46dp of every screen, gave four unrelated
/// controls identical visual weight, and still could not show which values
/// were selected without being opened one at a time.
///
/// The sheet is the researched mobile standard, and it brings the three things
/// the pill row could not:
///
///   * ROOM. Every genre is visible at once instead of behind a menu.
///   * A LIVE COUNT. The primary button reads "Show 24 titles" and updates as
///     the selection changes, so a filter that empties the catalogue is
///     visible BEFORE it is applied rather than as a blank screen after.
///   * BATCH APPLY. Changes land together on confirm. Applying each tap
///     individually makes the grid thrash under a sheet the user cannot see
///     past anyway.
///
/// Returns the new [ContentFilters], or null if the user backed out.
class FilterSheet extends StatefulWidget {
  final ContentFacets facets;
  final ContentFilters initial;

  /// Counts matches for a candidate filter set. Supplied by the caller so this
  /// widget never learns which repository it is talking to.
  final Future<int> Function(ContentFilters) countFor;

  const FilterSheet({
    super.key,
    required this.facets,
    required this.initial,
    required this.countFor,
  });

  static Future<ContentFilters?> show(
    BuildContext context, {
    required ContentFacets facets,
    required ContentFilters initial,
    required Future<int> Function(ContentFilters) countFor,
  }) {
    return showModalBottomSheet<ContentFilters>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => FilterSheet(
        facets: facets,
        initial: initial,
        countFor: countFor,
      ),
    );
  }

  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late ContentFilters _draft;
  int? _count;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _draft = widget.initial;
    _recount();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Debounced: tapping four genres quickly should cost one count, not four.
  void _recount() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () async {
      final candidate = _draft;
      final n = await widget.countFor(candidate);
      if (!mounted) return;
      // A slow count that resolves after the user has moved on must not
      // overwrite a newer one.
      if (candidate.signature != _draft.signature) return;
      setState(() => _count = n);
    });
  }

  void _update(ContentFilters next) {
    HapticFeedback.selectionClick();
    setState(() {
      _draft = next;
      _count = null;
    });
    _recount();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.82;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: VH.surface2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(VH.rSheet)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const _Grabber(),
            _Header(
              title: s.vhFilters,
              trailing: _draft.isEmpty
                  ? null
                  : _TextAction(
                      label: s.vhClearAll,
                      onTap: () => _update(_draft.cleared()),
                    ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(
                    VH.gutter, VH.s1, VH.gutter, VH.s4),
                children: <Widget>[
                  if (widget.facets.genres.isNotEmpty)
                    _Section(
                      title: s.vhFilterGenre,
                      child: Wrap(
                        spacing: VH.s2,
                        runSpacing: VH.s2,
                        children: widget.facets.genres
                            .map((g) => _Choice(
                                  label: g,
                                  selected: _draft.genres.contains(g),
                                  onTap: () =>
                                      _update(_draft.toggleGenre(g)),
                                ))
                            .toList(),
                      ),
                    ),
                  if (widget.facets.years.isNotEmpty)
                    _Section(
                      title: s.vhFilterYear,
                      child: Wrap(
                        spacing: VH.s2,
                        runSpacing: VH.s2,
                        children: <Widget>[
                          _Choice(
                            label: s.vhFilterAny,
                            selected: _draft.year == null,
                            onTap: () =>
                                _update(_draft.copyWith(clearYear: true)),
                          ),
                          ...widget.facets.years.map((y) => _Choice(
                                label: '$y',
                                selected: _draft.year == y,
                                onTap: () =>
                                    _update(_draft.copyWith(year: y)),
                              )),
                        ],
                      ),
                    ),
                  if (widget.facets.qualities.isNotEmpty)
                    _Section(
                      title: s.vhFilterQuality,
                      child: Wrap(
                        spacing: VH.s2,
                        runSpacing: VH.s2,
                        children: <Widget>[
                          _Choice(
                            label: s.vhFilterAny,
                            selected: _draft.quality == null,
                            onTap: () => _update(
                                _draft.copyWith(clearQuality: true)),
                          ),
                          ...widget.facets.qualities.map((q) => _Choice(
                                label: q,
                                selected: _draft.quality == q,
                                onTap: () =>
                                    _update(_draft.copyWith(quality: q)),
                              )),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            _ApplyBar(
              // The button is deliberately disabled at zero: letting someone
              // confirm their way to a blank screen is a worse outcome than a
              // dead button that says why.
              count: _count,
              onApply: (_count ?? 1) > 0
                  ? () => Navigator.of(context).pop(_draft)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ApplyBar extends StatelessWidget {
  final int? count;
  final VoidCallback? onApply;

  const _ApplyBar({required this.count, required this.onApply});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final label = count == null
        ? s.vhFilters
        : (count == 0 ? s.vhSearchNoResults : s.vhShowResults(count!));

    return Container(
      padding: const EdgeInsets.fromLTRB(VH.gutter, VH.s3, VH.gutter, VH.s3),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: VH.hairline)),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 46,
        child: FilledButton(
          onPressed: onApply,
          style: FilledButton.styleFrom(
            backgroundColor: VH.textPrimary,
            foregroundColor: VH.textInverse,
            disabledBackgroundColor: VH.surface3,
            disabledForegroundColor: VH.textTertiary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(VH.rControl),
            ),
          ),
          child: Text(
            label,
            style: VH.label.copyWith(
              color: onApply == null ? VH.textTertiary : VH.textInverse,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return Padding(
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
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _Header({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(VH.gutter, VH.s2, VH.s2, VH.s2),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(title, style: VH.heading)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _TextAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: VH.s3),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: VH.label.copyWith(color: VH.textSecondary)),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: VH.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: VH.s3),
            child: Text(
              // Small caps: section labels should read as structure, not as
              // another option competing with the chips beneath them.
              title.toUpperCase(),
              style: VH.label.copyWith(
                color: VH.textTertiary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VH.rPill),
      child: AnimatedContainer(
        duration: VH.fast,
        curve: VH.ease,
        // NO `alignment`, and NO fixed height. Both were the bug: a Container
        // with an alignment expands to its MAXIMUM constraint, which inside a
        // Wrap is the whole row - so every chip took a line to itself and the
        // sheet turned into a stack of full-width bars. Padding sizes it to
        // the label, which is what lets a Wrap actually wrap.
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? VH.textPrimary : VH.surface3,
          borderRadius: BorderRadius.circular(VH.rPill),
          border: Border.all(
            color: selected ? Colors.transparent : VH.hairline,
          ),
        ),
        child: Text(
          label,
          style: VH.label.copyWith(
            color: selected ? VH.textInverse : VH.textSecondary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
