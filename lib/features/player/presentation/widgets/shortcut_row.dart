import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/ui/tv_focus.dart';
import '../../../../core/theme/app_colors.dart';
import '../player_provider.dart';
import '../shortcut_item.dart';
import '../../domain/speed_format.dart';
import '../../../../core/localization/app_strings.dart';

/// Phase 15: MX Player parity for shortcut row.
///
/// Design rules (verified against MX Player Video 4 screen recording):
/// - Collapsed: a horizontally scrollable Row containing `visibleItems`
///   followed by the expand chevron `>` AS THE LAST ITEM INSIDE the same
///   scroll view (NOT outside it on the far right).
/// - Expanded: a single horizontally scrollable Row of ALL shortcuts
///   (not a 2-row grid as in earlier phases), followed by the collapse
///   chevron `<` as the last item.
/// - Expand/collapse chevron uses the SAME 48-circle styling as other
///   shortcut buttons (gray bg, white icon), not the previous blue accent.
///
/// Phase 45 (audit): MX Player V3 landscape uses dark translucent
/// CIRCLE backgrounds; portrait uses plain WHITE icons with NO circle
/// bg (verified frames 5 vs 20 of 180939). We expose [isPortrait] so
/// the caller can pick the right styling. Active items are shown as a
/// solid BLUE filled circle regardless of orientation.
/// MX geometry (measured on its portrait and landscape screenshots): one
/// slot every 63 dp from the left edge, so the first item sits under the back
/// arrow; 44 dp circles; the "1X" text at 15 sp.
const double _slot = 63;
const double _circle = 44;

class ShortcutRow extends StatelessWidget {
  final List<ShortcutItem> visibleItems;
  final Set<ShortcutItem> activeItems;
  final bool expanded;
  final void Function(ShortcutItem) onItemTap;
  final VoidCallback onToggleExpand;
  /// Phase 45 (audit): portrait orientation → plain white icons.
  /// Defaults to false (landscape style) for backward compatibility.
  final bool isPortrait;
  /// Phase 45 (audit): MX Player shows the speed shortcut as a plain
  /// text label like "1X" / "1.5X" (no icon, no circle). When the user
  /// has set a non-1.0 speed we render the shortcut differently.
  final double currentSpeed;
  /// Phase 45 (audit): when [audioEffectActive] is true, the Audio
  /// Effect shortcut shows a RED DOT badge top-right of its icon to
  /// signal that an effect is currently engaged (verified frame 11).
  final bool audioEffectActive;

  /// Loop mode — drives the loop shortcut icon (off/one/all).
  final LoopMode loopMode;

  /// All available items shown when expanded. Defaults to ShortcutItem.values
  /// minus customiseItems (which lives in the More menu).
  final List<ShortcutItem>? allItemsOverride;

  /// The viewer's own shortcuts (the collapsed row). Expanded, they stay
  /// first, where the viewer last saw them: in the enum's order they moved
  /// to the far end, behind nine rarely used ones.
  final Set<ShortcutItem> pinned;

  const ShortcutRow({
    super.key,
    required this.visibleItems,
    required this.activeItems,
    required this.expanded,
    required this.onItemTap,
    required this.onToggleExpand,
    this.allItemsOverride,
    this.isPortrait = false,
    this.currentSpeed = 1.0,
    this.audioEffectActive = false,
    this.loopMode = LoopMode.off,
    this.pinned = const {},
  });

  List<ShortcutItem> get _expandedItems {
    if (allItemsOverride != null) return allItemsOverride!;
    final all = ShortcutItem.values
        .where((i) => i != ShortcutItem.customiseItems)
        .toList();
    return [
      ...all.where(pinned.contains),
      ...all.where((i) => !pinned.contains(i)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final items = expanded ? _expandedItems : visibleItems;
    // +1 for the trailing expand/collapse chevron
    // Phase 16: Collapsed = no labels (more compact, MX Player parity).
    //           Expanded = with labels (matches MX Player landscape view).
    // Expanded, the labels hang under the circles in a box as tall as the
    // tallest of them: 28 dp holds two Latin lines, and a Burmese line alone
    // is nearly that tall.
    var labelBox = 28.0;
    if (expanded) {
      final s = AppStrings.of(context);
      for (final i in items) {
        labelBox = math.max(labelBox, shortcutLabelFit(context, i.labelIn(s)).height);
      }
    }
    return SizedBox(
      height: expanded ? 6 + _circle + 6 + labelBox + 6 : 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: items.length + 1,
        // The slot carries the spacing; MX has no extra gap.
        separatorBuilder: (_, __) => const SizedBox.shrink(),
        itemBuilder: (_, i) {
          if (i < items.length) {
            final item = items[i];
            return _ShortcutButton(
              key: ValueKey(item.name),
              item: item,
              labelBox: labelBox,
              isActive: activeItems.contains(item),
              showLabel: expanded,
              onTap: () => onItemTap(item),
              isPortrait: isPortrait,
              currentSpeed: currentSpeed,
              audioEffectActive: audioEffectActive,
              loopMode: loopMode,
            );
          }
          return _ExpandButton(
            labelBox: labelBox,
            expanded: expanded,
            onTap: onToggleExpand,
            isPortrait: isPortrait,
          );
        },
      ),
    );
  }
}

class _ShortcutButton extends StatelessWidget {
  final ShortcutItem item;
  final bool isActive;
  final bool showLabel;
  final VoidCallback onTap;
  final bool isPortrait;
  final double currentSpeed;
  final bool audioEffectActive;
  final LoopMode loopMode;
  final double labelBox;

  const _ShortcutButton({
    super.key,
    required this.item,
    this.labelBox = 28,
    required this.isActive,
    required this.showLabel,
    required this.onTap,
    this.isPortrait = false,
    this.currentSpeed = 1.0,
    this.audioEffectActive = false,
    this.loopMode = LoopMode.off,
  });

  @override
  Widget build(BuildContext context) {
    // Phase 45 (audit): MX Player V3 shows the playback-speed shortcut
    // as a plain text label like "1X" or "1.5X" instead of an icon —
    // verified in frame 11 of 180939 (landscape) and frame 20 (portrait).
    // The text-only style applies in BOTH orientations.
    final isSpeedShortcut = item == ShortcutItem.playbackSpeed;
    // Phase 45 (audit): Audio Effect gets a small RED DOT badge when
    // any effect is currently engaged (frame 11 shows the dot).
    final showRedDot =
        item == ShortcutItem.audioEffect && audioEffectActive;

    final iconBox = _buildIconBox(isSpeedShortcut, showRedDot);

    return RemoteTappable(
      onTap: onTap,
      // Collapsed, the row shows icons only: the label is the shortcut's
      // name for TalkBack (expanded, its visible label says it).
      semanticLabel: showLabel ? null : item.labelIn(AppStrings.of(context)),
      child: SizedBox(
        width: _slot,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // Collapsed and expanded, the circle's centre stays 28 dp down the
          // row — where MX keeps it — and the labels hang below.
          mainAxisAlignment:
              showLabel ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [
            if (showLabel) const SizedBox(height: 6),
            iconBox,
            if (showLabel) ...[
              const SizedBox(height: 6),
              // MX: one line at 11 sp ("Sleep Timer", "A - B Repeat"),
              // wrapping only when it still does not fit ("Customise /
              // Items"). Two long neighbours used to be allowed 7 dp into
              // each other's slot and ran together ("Sleep TimerA - B
              // Repeat", seen on TV and tablet renders), so a label keeps
              // to its own slot less a 4 dp gap: a little too long and it
              // is set a touch smaller (down to 10 sp), longer than that
              // and it wraps.
              SizedBox(
                height: labelBox,
                child: _ShortcutLabel(
                  // Phase 45 (audit): the Speed shortcut already shows
                  // its value ("1X"/"1.5X"/"2X") as the icon text itself;
                  // the label under it just says "Speed".
                  item.labelIn(AppStrings.of(context)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Phase 45 (audit): build the 44px icon box according to MX Player
  /// styling rules:
  ///   - Active toggle: solid BLUE filled circle (e.g. Loop active).
  ///   - Audio Effect with engaged effect: red dot badge top-right.
  ///   - Speed shortcut: PLAIN TEXT label ("1X" / "1.5X" / "2X"), no icon.
  ///   - Landscape inactive: dark translucent circle background.
  ///   - Portrait inactive: NO background, plain white icon.
  Widget _buildIconBox(bool isSpeedShortcut, bool showRedDot) {
    // Active state (any orientation): always a blue circle.
    if (isActive) {
      return Container(
        width: _circle,
        height: _circle,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.specActiveToggle,
        ),
        child: isSpeedShortcut
            ? Center(child: _speedText())
            : Stack(
              alignment: Alignment.center,
              children: [
                Icon(_effectiveIcon(), color: Colors.white, size: 28),
                if (_loopBadge() case final badge?) badge,
              ],
            ),
      );
    }

    // Speed shortcut renders text-only (no circle bg) when inactive.
    if (isSpeedShortcut) {
      return SizedBox(
        width: _circle,
        height: _circle,
        child: Center(child: _speedText()),
      );
    }

    // Portrait inactive: plain white icon, no background.
    if (isPortrait) {
      return SizedBox(
        width: _circle,
        height: _circle,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(_effectiveIcon(), color: Colors.white, size: 28),
            if (showRedDot) _redDot(),
            if (_loopBadge() case final badge?) badge,
          ],
        ),
      );
    }

    // Landscape inactive: dark translucent circle.
    return Container(
      width: _circle,
      height: _circle,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.shortcutInactive,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(_effectiveIcon(), color: Colors.white, size: 28),
          if (showRedDot) _redDot(),
          if (_loopBadge() case final badge?) badge,
        ],
      ),
    );
  }

  /// Phase 45 (audit): render the speed label like MX Player ("1X",
  /// "1.5X", "2X"). Whole-number speeds drop the decimal point.
  Widget _speedText() {
    return Text(
      '${formatSpeed(currentSpeed)}X',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  /// Returns the correct icon for the loop shortcut based on [loopMode].
  /// All other items use their standard icon.
  IconData _effectiveIcon() {
    if (item == ShortcutItem.loop) {
      switch (loopMode) {
        case LoopMode.one:
          return Icons.repeat_one;
        case LoopMode.all:
          return Icons.repeat;
        case LoopMode.off:
          return Icons.repeat;
      }
    }
    return item.icon;
  }

  /// Loop-one is represented by the `repeat_one` icon, which already shows
  /// a clear "1" inside the loop arrows (MX Player parity). We deliberately
  /// no longer stack a second red "1" badge on top — one "1" is cleaner.
  Widget? _loopBadge() => null;

  Widget _redDot() {
    return const Positioned(
      top: 6,
      right: 6,
      child: SizedBox(
        width: 8,
        height: 8,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color(0xFFE53935), // red
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// Phase 15: Expand/collapse chevron — sits INSIDE the same scrollable row
/// as the shortcut buttons. Same 48px circle styling as other shortcuts
/// in landscape; plain icon in portrait (Phase 45 audit).
class _ExpandButton extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;
  final bool isPortrait;
  final double labelBox;

  const _ExpandButton({
    this.labelBox = 28,
    required this.expanded,
    required this.onTap,
    this.isPortrait = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconWidget = Icon(
      expanded ? Icons.chevron_left : Icons.chevron_right,
      color: Colors.white,
      size: 24,
    );

    // MX: the chevron gets a SMALL circle in landscape (about 28 dp), none
    // in portrait — it is a way on, not one of the shortcuts.
    return RemoteTappable(
      onTap: onTap,
      semanticLabel: expanded
          ? MaterialLocalizations.of(context).expandedIconTapHint
          : MaterialLocalizations.of(context).collapsedIconTapHint,
      child: SizedBox(
        width: _slot,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment:
              expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [
            if (expanded) const SizedBox(height: 6),
            isPortrait
                ? SizedBox(width: _circle, height: _circle, child: iconWidget)
                : Container(
                    width: 28,
                    height: 28,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.shortcutInactive,
                    ),
                    child: iconWidget,
                  ),
            if (expanded) ...[
              // Empty label slot to align with sibling buttons
              SizedBox(height: 6 + labelBox),
            ],
          ],
        ),
      ),
    );
  }
}

/// A shortcut's label under its circle: see the note where it is used.
/// Whether [t] is written without spaces between words (Burmese, Thai):
/// such text breaks between syllables, which is how it is written, so a line
/// break inside a space-free run is not a word cut in half.
bool _breaksWithoutSpaces(String t) => t.runes.any((r) =>
    (r >= 0x1000 && r <= 0x109F) || // Myanmar
    (r >= 0xAA60 && r <= 0xAA7F) || // Myanmar Extended-A
    (r >= 0xA9E0 && r <= 0xA9FF) || // Myanmar Extended-B
    (r >= 0x0E00 && r <= 0x0E7F)); // Thai

/// How a shortcut's label is set under its circle: the font size, one line
/// or two, and the height that takes.
///
/// 11 sp on one line; a little smaller (to 10) rather than wrap; else two
/// lines, never a Latin word broken in half ("Backgroun / d"), smaller only
/// if a word still does not fit. Burmese and Thai have no spaces between
/// words: they were measured as one long "word" and shrunk to fit a single
/// line — "အပေါ်အောက်လှန်" came out near 6 sp, unreadable. They wrap
/// between syllables instead, and the row grows to hold their taller lines
/// (test/player_layout_test.dart).
({double size, int lines, double height}) shortcutLabelFit(
    BuildContext context, String text) {
  const base = _ShortcutLabel._base;
  const min = _ShortcutLabel._min;
  // A text set to fill its box exactly can still come out a hair wider and
  // be cut off, so it is fitted 1 dp inside its room.
  const fit = _slot - 4 - 1;
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.of(context);
  final style = DefaultTextStyle.of(context)
      .style
      .merge(const TextStyle(color: Colors.white, fontSize: base));
  TextPainter lay(String t, double size, int lines, [double? width]) =>
      TextPainter(
        text: TextSpan(text: t, style: style.copyWith(fontSize: size)),
        textDirection: direction,
        textScaler: scaler,
        maxLines: lines,
        ellipsis: lines > 1 ? '…' : null,
      )..layout(maxWidth: width ?? double.infinity);
  double widthOf(String t, double size) {
    final p = lay(t, size, 1);
    final w = p.width;
    p.dispose();
    return w;
  }

  ({double size, int lines, double height}) done(double size, int lines) {
    final p = lay(text, size, lines, fit);
    final h = p.height;
    p.dispose();
    return (size: size, lines: lines, height: h);
  }

  final width = widthOf(text, base);
  if (width <= fit) return done(base, 1);
  if (width * min / base <= fit) return done(base * fit / width, 1);
  // Two lines. The longest word that may not be broken must fit a line.
  final longest = text
      .split(' ')
      .where((w) => !_breaksWithoutSpaces(w))
      .map((w) => widthOf(w, base))
      .fold<double>(0, math.max);
  var size = longest > fit ? base * fit / longest : base;
  // And the whole text must fit two lines at that size.
  for (; size > 8; size -= 0.5) {
    final p = lay(text, size, 2, fit);
    final over = p.didExceedMaxLines;
    p.dispose();
    if (!over) break;
  }
  return done(size, 2);
}

class _ShortcutLabel extends StatelessWidget {
  const _ShortcutLabel(this.text);

  final String text;

  static const double _base = 11;
  static const double _min = 10;

  @override
  Widget build(BuildContext context) {
    const room = _slot - 4;
    final style = DefaultTextStyle.of(context)
        .style
        .merge(const TextStyle(color: Colors.white, fontSize: _base));
    final f = shortcutLabelFit(context, text);
    final size = f.size;
    final lines = f.lines;
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: room,
        child: Text(
          text,
          textAlign: TextAlign.center,
          softWrap: lines > 1,
          style: style.copyWith(fontSize: size),
          maxLines: lines,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
