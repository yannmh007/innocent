import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/services/video_player/models/subtitle_track_info.dart';
import 'player_ui.dart';

/// The CC panel: choose the subtitle track (or none) right here, load one
/// from a file, look online, and reach the delay, text style and position.
/// A side panel sideways, a bottom sheet upright (PlayerPanel).
///
/// 12 Nov 2026: the tracks were a sheet behind a "Subtitle track" row, the
/// panel a 90 % black slab with the controls showing through it, the same
/// right-hand panel even with the phone upright. Choosing a track is what
/// CC is pressed for, so it is now one tap, as in MX Player.
///
/// 26 Nov 2026, the owner: "English, Burmese in a rectangle — as MX, all of
/// it". In MX's order: open a file; the tracks, each a check box, in a box
/// (the one on is the one showing; tapped again, none shows — there is no
/// "Off" row); online subtitles; and Settings, a row that opens below
/// itself to the delay, the text style and the position.
class SubtitlePanel extends StatelessWidget {
  final List<SubtitleTrackInfo> tracks;

  /// The track showing: the viewer's choice, else the engine's own; null
  /// for none.
  final SubtitleTrackInfo? current;
  final ValueChanged<SubtitleTrackInfo?> onSelectTrack;
  final VoidCallback onOpen;
  final VoidCallback onDelay;
  final VoidCallback onTextStyle;
  final VoidCallback onLayout;
  final VoidCallback onOnlineSubtitles;
  final VoidCallback onDismiss;

  const SubtitlePanel({
    super.key,
    required this.tracks,
    required this.current,
    required this.onSelectTrack,
    required this.onOpen,
    required this.onDelay,
    required this.onTextStyle,
    required this.onLayout,
    required this.onOnlineSubtitles,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return PlayerPanel(
      title: s.subtitle,
      onDismiss: onDismiss,
      children: [
        PanelRow(
          icon: Icons.folder_open_outlined,
          title: s.loadExternalSubtitle,
          onTap: onOpen,
        ),
        if (tracks.isNotEmpty)
          PanelCheckBox(rows: [
            for (final t in tracks)
              PanelCheck(
                title: t.displayName,
                // By id: the engine sends the list afresh (a file loaded,
                // a track found late), and the chosen track is then an
                // older copy of one in it.
                value: t.id == current?.id,
                // The one on, tapped again: none.
                onTap: () => onSelectTrack(t.id == current?.id ? null : t),
              ),
          ]),
        // A row, not the header's corner: "Online စာတန်းထိုးများ" was
        // cut to "Online စာတန်းထိုးမ…" beside the title.
        PanelRow(
          icon: Icons.travel_explore_rounded,
          title: s.onlineSubtitles,
          onTap: onOnlineSubtitles,
        ),
        PanelExpandRow(
          icon: Icons.settings_outlined,
          title: s.settingsTitle,
          children: [
            PanelRow(
              icon: Icons.av_timer_rounded,
              title: s.subtitleDelayMenu.replaceAll('\n', ' '),
              chevron: true,
              onTap: onDelay,
            ),
            PanelRow(
              icon: Icons.text_fields_rounded,
              title: s.pwTextStyle,
              chevron: true,
              onTap: onTextStyle,
            ),
            PanelRow(
              icon: Icons.format_align_center_rounded,
              title: s.pwPosLayout,
              chevron: true,
              onTap: onLayout,
            ),
          ],
        ),
      ],
    );
  }
}
