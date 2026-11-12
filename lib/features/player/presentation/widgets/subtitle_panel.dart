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
        PanelSection(
          first: true,
          label: s.plTracks,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PanelRow(
                choice: true,
                title: s.off,
                selected: current == null,
                onTap: () => onSelectTrack(null),
              ),
              for (final t in tracks)
                PanelRow(
                  choice: true,
                  title: t.displayName,
                  // By id: the engine sends the list afresh (a file loaded,
                  // a track found late), and the chosen track is then an
                  // older copy of one in it.
                  selected: t.id == current?.id,
                  onTap: () => onSelectTrack(t),
                ),
              PanelRow(
                icon: Icons.folder_open_outlined,
                title: s.loadExternalSubtitle,
                onTap: onOpen,
              ),
              // A row, not the header's corner: "Online စာတန်းထိုးများ" was
              // cut to "Online စာတန်းထိုးမ…" beside the title.
              PanelRow(
                icon: Icons.travel_explore_rounded,
                title: s.onlineSubtitles,
                onTap: onOnlineSubtitles,
              ),
            ],
          ),
        ),
        PanelSection(
          label: s.settingsTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
        ),
      ],
    );
  }
}
