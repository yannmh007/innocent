import 'package:flutter/material.dart';

import '../../../../core/services/video_player/models/audio_track_info.dart';
import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// The audio track sheet (♪): the film's tracks, the playing one checked.
/// Subtitle tracks are chosen in the CC panel itself (SubtitlePanel).
class TrackSelectionSheet<T> extends StatelessWidget {
  final String title;
  final List<T> tracks;
  final T? currentTrack;
  final String Function(T) labelFor;

  /// What makes two copies of a track the same track: the engine sends
  /// its list afresh, and the chosen one is then an older copy.
  final String Function(T) idFor;
  final ValueChanged<T?> onSelect;

  const TrackSelectionSheet({
    super.key,
    required this.title,
    required this.tracks,
    required this.currentTrack,
    required this.labelFor,
    required this.idFor,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final current = currentTrack;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerSheetHeader(title: title),
        // The list gives way, not the sheet: on a phone held sideways
        // the sheet is about 200 dp tall (test/player_layout_test.dart).
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(
                PlayerUi.pad(context) - 4, 8, PlayerUi.pad(context) - 4, 16),
            children: [
              for (final t in tracks)
                PanelRow(
                  choice: true,
                  title: labelFor(t),
                  selected: current != null && idFor(t) == idFor(current),
                  onTap: () => onSelect(t),
                ),
              if (tracks.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    AppStrings.of(context).noTracksAvailable,
                    style: PlayerUi.body,
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// The audio track sheet.
  static Future<void> showAudio(
    BuildContext context, {
    required List<AudioTrackInfo> tracks,
    required AudioTrackInfo? current,
    required ValueChanged<AudioTrackInfo?> onSelect,
  }) {
    return showPlayerSheet<void>(
      context,
      builder: (_) => TrackSelectionSheet<AudioTrackInfo>(
        title: AppStrings.of(context).audioTrack,
        tracks: tracks,
        currentTrack: current,
        labelFor: (t) => t.displayName,
        idFor: (t) => t.id,
        onSelect: (t) {
          onSelect(t);
          Navigator.of(context).pop();
        },
      ),
    );
  }
}
