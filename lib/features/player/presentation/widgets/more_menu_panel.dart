import 'package:flutter/material.dart';

import '../shortcut_item.dart';
import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

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

/// A row of ⋮'s "More" page: words alone, as MX's.
class MorePageRow {
  const MorePageRow({required this.title, required this.onTap});
  final String title;
  final VoidCallback onTap;
}

/// A section of ⋮'s "More" page (MX's "Tools", "Help").
class MorePageSection {
  const MorePageSection({required this.label, required this.rows});
  final String label;
  final List<MorePageRow> rows;
}

/// The ⋮ panel: the player's other actions as a grid of tiles, then the
/// Video display switch and the choice of shortcuts on the row under the
/// top bar. A side panel sideways, a bottom sheet upright (PlayerPanel).
///
/// As MX's (the owner, 26 Nov 2026: "11 tiles and More"; reference lab
/// 45857557804): MX's tiles in MX's order, the last a "More ›" tile that
/// turns the panel to a second page in place — "← More", then rows of
/// words in sections ([moreSections]) — whose ← turns it back.
///
/// 12 Nov 2026, redrawn on player_ui.dart: it was a 92 % grey over a 38 %
/// scrim with the controls still drawn under it, 47 dp outline rings, and
/// a "Video display" switch that hid the sixteen actions as well as the
/// picture. The switch now turns the picture off and nothing else.
class MoreMenuPanel extends StatefulWidget {
  final List<MoreMenuItemData> items;

  /// The "More ›" page; no "More ›" tile without it.
  final List<MorePageSection> moreSections;
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
    this.moreSections = const [],
  });

  @override
  State<MoreMenuPanel> createState() => _MoreMenuPanelState();
}

class _MoreMenuPanelState extends State<MoreMenuPanel> {
  bool _more = false;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final w = widget;
    if (_more) {
      // MX's second page: "← More", then its sections of words.
      return PlayerPanel(
        // Its own key: the first page's scroll was kept, and "More" opened
        // half way down its list (the layout test's photographs).
        key: const ValueKey('more-page'),
        title: s.moreOptions,
        onBack: () => setState(() => _more = false),
        onDismiss: w.onDismiss,
        children: [
          for (var i = 0; i < w.moreSections.length; i++)
            PanelSection(
              label: w.moreSections[i].label,
              first: i == 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final r in w.moreSections[i].rows)
                    // A tile's label may break in two; a row's never.
                    PanelRow(
                        title: r.title.replaceAll('\n', ' '), onTap: r.onTap),
                ],
              ),
            ),
        ],
      );
    }
    // No title, upright or sideways: MX's ⋮ has none, the tiles are the
    // first thing (the owner, 26 Nov 2026: "hide the word More").
    return PlayerPanel(
      key: const ValueKey('more-tiles'),
      onDismiss: w.onDismiss,
      children: [
        PanelGrid(
          children: [
            for (final item in w.items)
              PanelTile(
                icon: item.icon,
                label: item.label,
                dot: item.hasNotificationDot,
                onTap: item.onTap,
              ),
            if (w.moreSections.isNotEmpty)
              PanelTile(
                icon: Icons.chevron_right_rounded,
                label: s.moreOptions,
                onTap: () => setState(() => _more = true),
              ),
          ],
        ),
        const SizedBox(height: 14),
        const Divider(height: 1, thickness: 1, color: PlayerUi.hairline),
        const SizedBox(height: 6),
        PanelSwitchRow(
          icon: Icons.ondemand_video_outlined,
          title: s.scVideoDisplay,
          value: w.videoDisplayEnabled,
          onChanged: w.onVideoDisplayToggle,
        ),
        PanelSwitchRow(
          icon: Icons.dashboard_customize_outlined,
          title: s.shortcuts,
          value: w.visibleShortcuts.isNotEmpty,
          onChanged: w.onShortcutsToggle,
        ),
        const SizedBox(height: 6),
        PanelCard(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: PanelGrid(
            columns: 2,
            children: [
              for (final item in ShortcutItem.available())
                _ShortcutCheck(
                  label: item.labelIn(s).replaceAll('\n', ' '),
                  value: w.visibleShortcuts.contains(item),
                  onChanged: () => w.onShortcutToggle(item),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One shortcut of the checklist: a rounded check box and its name. The
/// row takes the tap; the box is the one control TalkBack reads.
class _ShortcutCheck extends StatelessWidget {
  final String label;
  final bool value;
  final VoidCallback onChanged;

  const _ShortcutCheck({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: InkWell(
        onTap: onChanged,
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: ExcludeFocus(
                    child: Checkbox(
                      value: value,
                      onChanged: (_) => onChanged(),
                      activeColor: PlayerUi.accent,
                      checkColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                      side: const BorderSide(
                          color: PlayerUi.textDisabled, width: 1.5),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: PlayerUi.textPrimary,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
