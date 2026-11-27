import 'package:flutter/material.dart';

import '../../../../core/services/video_player/models/audio_track_info.dart';
import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// The audio track sheet (♪): the film's tracks, the playing one checked;
/// under them, as MX's ♪ has its Synchronization, the audio delay (the
/// owner's choice of MX's extra rows, 26 Nov 2026), which opens
/// [AudioSyncSheet]. Subtitle tracks are chosen in the CC panel itself
/// (SubtitlePanel).
class TrackSelectionSheet<T> extends StatelessWidget {
  final String title;
  final List<T> tracks;
  final T? currentTrack;
  final String Function(T) labelFor;

  /// What makes two copies of a track the same track: the engine sends
  /// its list afresh, and the chosen one is then an older copy.
  final String Function(T) idFor;
  final ValueChanged<T?> onSelect;

  /// The audio delay now, in ms, and what a tap on its row does; no row
  /// without [onDelay].
  final int delayMs;
  final VoidCallback? onDelay;

  const TrackSelectionSheet({
    super.key,
    required this.title,
    required this.tracks,
    required this.currentTrack,
    required this.labelFor,
    required this.idFor,
    required this.onSelect,
    this.delayMs = 0,
    this.onDelay,
  });

  @override
  Widget build(BuildContext context) {
    final current = currentTrack;
    final s = AppStrings.of(context);
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
                PlayerUi.pad(context) - 4, 2, PlayerUi.pad(context) - 4, 16),
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
                    s.noTracksAvailable,
                    style: PlayerUi.body,
                    textAlign: TextAlign.center,
                  ),
                ),
              // MX: a hairline under the tracks, then its rows in words
              // alone, from the content's edge.
              if (onDelay != null) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: Divider(
                      height: 1, thickness: 1, color: PlayerUi.hairline),
                ),
                PanelRow(
                  title: s.saDelay,
                  value: AudioSyncSheet.format(delayMs),
                  onTap: onDelay,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// The audio track sheet. [onDelay] closes it and opens [AudioSyncSheet].
  static Future<void> showAudio(
    BuildContext context, {
    required List<AudioTrackInfo> tracks,
    required AudioTrackInfo? current,
    required ValueChanged<AudioTrackInfo?> onSelect,
    int delayMs = 0,
    VoidCallback? onDelay,
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
        delayMs: delayMs,
        onDelay: onDelay == null
            ? null
            : () {
                Navigator.of(context).pop();
                onDelay();
              },
      ),
    );
  }
}

/// The audio delay, set by steps while the film plays behind (the sheet
/// lets the picture through and takes no barrier): − and + move it 50 ms
/// (the Settings slider's step), a tap on the value puts it back to 0. The
/// same value as Settings > Audio > Audio delay (IntSetting.audioDelay,
/// −2000..+2000 ms), which the player applies as it changes. Positive: the
/// sound later.
class AudioSyncSheet extends StatefulWidget {
  const AudioSyncSheet({
    super.key,
    required this.initialMs,
    required this.onChanged,
  });

  final int initialMs;
  final ValueChanged<int> onChanged;

  static const int min = -2000;
  static const int max = 2000;
  static const int step = 50;

  /// "+150 ms", "0 ms", "−200 ms".
  static String format(int ms) =>
      ms > 0 ? '+$ms ms' : (ms < 0 ? '−${-ms} ms' : '0 ms');

  static Future<void> show(
    BuildContext context, {
    required int initialMs,
    required ValueChanged<int> onChanged,
  }) {
    return showPlayerSheet<void>(
      context,
      // Judged by ear against the picture: the film stays as it is.
      barrierColor: Colors.transparent,
      builder: (_) =>
          AudioSyncSheet(initialMs: initialMs, onChanged: onChanged),
    );
  }

  @override
  State<AudioSyncSheet> createState() => _AudioSyncSheetState();
}

class _AudioSyncSheetState extends State<AudioSyncSheet> {
  late int _ms;

  @override
  void initState() {
    super.initState();
    _ms = widget.initialMs.clamp(AudioSyncSheet.min, AudioSyncSheet.max);
  }

  void _set(int v) {
    final next = v.clamp(AudioSyncSheet.min, AudioSyncSheet.max);
    if (next == _ms) return;
    setState(() => _ms = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerSheetHeader(
          title: s.saDelay,
          divider: false,
          trailing: PanelHeaderAction(
            label: s.done,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                PlayerUi.pad(context), 0, PlayerUi.pad(context) - 8, 16),
            child: PanelStepperRow(
              icon: Icons.schedule,
              label: s.pwTiming,
              value: AudioSyncSheet.format(_ms),
              onMinus: () => _set(_ms - AudioSyncSheet.step),
              onPlus: () => _set(_ms + AudioSyncSheet.step),
              onReset: () => _set(0),
              minusTooltip: s.pwDecrease(s.saDelay),
              plusTooltip: s.pwIncrease(s.saDelay),
            ),
          ),
        ),
      ],
    );
  }
}
