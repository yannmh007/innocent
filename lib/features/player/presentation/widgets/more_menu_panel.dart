import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../shortcut_item.dart';

/// Audit fix (B4): logical grouping for the More menu items so the
/// 14-item grid scans as five small sections instead of one
/// overwhelming wall. Categories chosen by user-task: what is the
/// person trying to do?
enum MoreMenuCategory {
  playback('Playback'),
  edit('Edit'),
  library('Library'),
  action('Action'),
  info('Info');

  final String label;
  const MoreMenuCategory(this.label);
}

/// More menu item descriptor
class MoreMenuItemData {
  final String label;
  final IconData icon;
  final bool hasNotificationDot;
  final VoidCallback onTap;

  /// Audit fix (B4): which section this item belongs to. Defaults to
  /// `playback` so existing callers that don't specify still
  /// render correctly (in the Playback section).
  final MoreMenuCategory category;

  const MoreMenuItemData({
    required this.label,
    required this.icon,
    required this.onTap,
    this.hasNotificationDot = false,
    this.category = MoreMenuCategory.playback,
  });
}

/// Player ▸ Video Options overlay (innocent_player_options_spec).
///
/// Two sections, each gated by a master Material switch in its header:
///   1. Video Display — 4-column grid of circular icon buttons
///   2. Shortcuts     — 2-column checkbox grid of toggleable controls
///
/// One widget for both orientations: a bottom-sheet in portrait, a
/// right-side panel in landscape. Only the container placement changes.
class MoreMenuPanel extends StatelessWidget {
  final List<MoreMenuItemData> items;
  final bool videoDisplayEnabled;
  final Set<ShortcutItem> visibleShortcuts;
  final ValueChanged<bool> onVideoDisplayToggle;
  final ValueChanged<bool> onShortcutsToggle;
  final ValueChanged<ShortcutItem> onShortcutToggle;
  final VoidCallback onDismiss;

  const MoreMenuPanel({
    super.key,
    required this.items,
    required this.videoDisplayEnabled,
    required this.visibleShortcuts,
    required this.onVideoDisplayToggle,
    required this.onShortcutsToggle,
    required this.onShortcutToggle,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isPortrait = size.height >= size.width;

    final content = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Video Display section ──
          _SectionHeader(
            label: 'Video Display',
            value: videoDisplayEnabled,
            onChanged: onVideoDisplayToggle,
          ),
          const Divider(height: 1, color: Color(0xFF2A2A2A)),
          if (videoDisplayEnabled) ...[
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                // Fixed-height cells keep the grid compact and identical in
                // both orientations (56 dp circle + 6 dp gap + a wrapping
                // 13 sp label ≈ 91 dp).
                mainAxisExtent: 92,
                crossAxisSpacing: 0,
                mainAxisSpacing: 4,
              ),
              itemCount: items.length,
              itemBuilder: (_, i) => _MoreMenuItem(data: items[i]),
            ),
          ],
          const SizedBox(height: 14),
          // ── Shortcuts section ──
          _SectionHeader(
            label: 'Shortcuts',
            value: visibleShortcuts.isNotEmpty,
            onChanged: onShortcutsToggle,
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: AppColors.specInnerPanel,
              borderRadius: BorderRadius.circular(8),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisExtent: 38,
                crossAxisSpacing: 12,
                mainAxisSpacing: 0,
              ),
              itemCount: ShortcutItem.values.length,
              itemBuilder: (_, i) {
                final item = ShortcutItem.values[i];
                return _ShortcutCheckRow(
                  label: item.label.replaceAll('\n', ' '),
                  value: visibleShortcuts.contains(item),
                  onChanged: (_) => onShortcutToggle(item),
                );
              },
            ),
          ),
        ],
      ),
    );

    final sheet = Material(
      color: AppColors.specSheetBg.withOpacity(0.92),
      borderRadius: isPortrait
          ? const BorderRadius.vertical(top: Radius.circular(16))
          : null,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: !isPortrait,
        child: content,
      ),
    );

    return Stack(
      children: [
        // Dismiss scrim
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
            child: Container(color: Colors.black38),
          ),
        ),
        // Portrait → bottom-sheet; landscape → right-side panel.
        if (isPortrait)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ConstrainedBox(
              // Compact bottom-sheet ≈ 2/5 of the screen; the content
              // scrolls within so the video stays visible above it.
              constraints: BoxConstraints(maxHeight: size.height * 0.45),
              child: sheet,
            ),
          )
        else
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            // Narrower panel removes the wasted side gaps in landscape.
            width: (size.width * 0.38).clamp(300.0, 420.0),
            child: sheet,
          ),
      ],
    );
  }
}

/// Section header: bold title on the left, compact master switch on the
/// right (spec: 22×13 track, ON #64B7FD, white thumb).
class _SectionHeader extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SectionHeader({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          // Material Switch scaled down toward the spec's small track.
          Transform.scale(
            scale: 0.7,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeColor: Colors.white,
              activeTrackColor: AppColors.specSwitchOn,
              inactiveThumbColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

class _MoreMenuItem extends StatelessWidget {
  final MoreMenuItemData data;

  const _MoreMenuItem({required this.data});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: data.onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              // 56 dp circular icon button with a faint white ring.
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.transparent,
                  border: Border.fromBorderSide(
                    BorderSide(color: AppColors.specRing, width: 1),
                  ),
                ),
                child: Icon(data.icon, color: Colors.white, size: 20),
              ),
              if (data.hasNotificationDot)
                const Positioned(
                  top: 5,
                  right: 4,
                  child: _NotificationDot(),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            data.label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationDot extends StatelessWidget {
  const _NotificationDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(
        color: AppColors.specNotifDot,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// One row in the Shortcuts grid: a 15 dp rounded checkbox + label.
class _ShortcutCheckRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool?> onChanged;

  const _ShortcutCheckRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: value,
              onChanged: onChanged,
              activeColor: AppColors.specCheckbox,
              checkColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(3),
              ),
              side: const BorderSide(color: Colors.white38, width: 1.5),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}
