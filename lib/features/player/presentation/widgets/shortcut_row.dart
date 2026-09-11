import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../player_provider.dart';
import '../shortcut_item.dart';

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
  });

  List<ShortcutItem> get _expandedItems {
    if (allItemsOverride != null) return allItemsOverride!;
    return ShortcutItem.values
        .where((i) => i != ShortcutItem.customiseItems)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final items = expanded ? _expandedItems : visibleItems;
    // +1 for the trailing expand/collapse chevron
    // Phase 16: Collapsed = no labels (more compact, MX Player parity).
    //           Expanded = with labels (matches MX Player landscape view).
    return SizedBox(
      height: expanded ? 88 : 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: items.length + 1,
        // Portrait floats plain icons (no circle bg) so the same gap reads
        // wider — keep the portrait gap tight so the row sits close like
        // the landscape (circled) row. Landscape keeps 10.
        separatorBuilder: (_, __) => SizedBox(width: isPortrait ? 3 : 10),
        itemBuilder: (_, i) {
          if (i < items.length) {
            final item = items[i];
            return _ShortcutButton(
              key: ValueKey(item.name),
              item: item,
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

  const _ShortcutButton({
    super.key,
    required this.item,
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

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        // Phase 16: Narrower when label hidden (matches MX Player compact row).
        // Portrait (no circle bg) tightens further so icons sit close together.
        width: showLabel ? 64 : (isPortrait ? 44 : 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            iconBox,
            if (showLabel) ...[
              const SizedBox(height: 4),
              Text(
                // Phase 45 (audit): the Speed shortcut already shows
                // its value ("1X"/"1.5X"/"2X") as the icon text itself,
                // so duplicating "Speed" underneath would be redundant
                // and visually heavy. MX Player V3 just shows "Speed"
                // — but since our "icon" IS the speed text, we keep
                // the slot empty for it (alignment with sibling
                // buttons stays consistent).
                isSpeedShortcut ? 'Speed' : item.label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  height: 1.1,
                ),
                maxLines: 2,
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
        width: 36,
        height: 36,
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
        width: 36,
        height: 36,
        child: Center(child: _speedText()),
      );
    }

    // Portrait inactive: plain white icon, no background.
    if (isPortrait) {
      return SizedBox(
        width: 36,
        height: 36,
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
      width: 36,
      height: 36,
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
    final isWhole = (currentSpeed - currentSpeed.roundToDouble()).abs() < 0.01;
    final label = isWhole
        ? '${currentSpeed.toInt()}X'
        : '${currentSpeed.toStringAsFixed(currentSpeed.toString().endsWith("5") ? 1 : 2)}X';
    return Text(
      label,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14,
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

  const _ExpandButton({
    required this.expanded,
    required this.onTap,
    this.isPortrait = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconWidget = Icon(
      expanded ? Icons.chevron_left : Icons.chevron_right,
      color: Colors.white,
      size: 28,
    );

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: expanded ? 64 : (isPortrait ? 44 : 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            isPortrait
                ? SizedBox(width: 36, height: 36, child: iconWidget)
                : Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.shortcutInactive,
                    ),
                    child: iconWidget,
                  ),
            if (expanded) ...[
              const SizedBox(height: 4),
              // Empty label slot to align with sibling buttons
              const Text(
                '',
                style: TextStyle(fontSize: 9, height: 1.1),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
