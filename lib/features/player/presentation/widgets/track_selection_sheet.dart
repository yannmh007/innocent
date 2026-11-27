import 'package:flutter/material.dart';

import '../../../../core/services/video_player/models/audio_track_info.dart';
import '../../../../core/localization/app_strings.dart';
import 'player_ui.dart';

/// The audio track sheet (♪): the film's tracks, the playing one checked;
/// under them, as MX's ♪ has its Synchronization, the audio delay (the
/// owner's choice of MX's extra rows, 26 Nov 2026), which opens
/// [AudioSyncSheet]. Subtitle tracks are chosen in the CC panel itself
/// (SubtitlePanel).
///
/// MX's other ♪ items, the owner's choice of 27 Nov 2026 (docs/handoff_
/// 2026_11_27_beyond_mx.md P4), each only when the player gives its
/// callback: Disable as the last choice of the tracks (the film silent),
/// then under the hairline Stereo mode (stereo, mono, swapped), Volume
/// boost (above 100 %) and Night sound (loud moments down, speech up).
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

  /// ♪'s Disable: [disabled] marks it, [onDisable] chooses it.
  final bool disabled;
  final VoidCallback? onDisable;

  /// Stereo mode's value in words, and what a tap on its row does.
  final String? stereoLabel;
  final VoidCallback? onStereo;

  /// Volume boost's value ("150 %"), and what a tap on its row does.
  final String? boostLabel;
  final VoidCallback? onBoost;

  /// Night sound, and its switch.
  final bool night;
  final ValueChanged<bool>? onNight;

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
    this.disabled = false,
    this.onDisable,
    this.stereoLabel,
    this.onStereo,
    this.boostLabel,
    this.onBoost,
    this.night = false,
    this.onNight,
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
                  selected: !disabled &&
                      current != null &&
                      idFor(t) == idFor(current),
                  onTap: () => onSelect(t),
                ),
              if (onDisable != null)
                PanelRow(
                  choice: true,
                  title: s.audDisable,
                  selected: disabled,
                  onTap: onDisable,
                ),
              if (tracks.isEmpty && onDisable == null)
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
              if (onStereo != null)
                PanelRow(
                  title: s.audStereoMode,
                  value: stereoLabel,
                  onTap: onStereo,
                ),
              if (onBoost != null)
                PanelRow(
                  title: s.saBoost,
                  value: boostLabel,
                  onTap: onBoost,
                ),
              if (onNight != null)
                _HeldSwitch(
                  title: s.audNight,
                  initial: night,
                  onChanged: onNight!,
                ),
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
    bool disabled = false,
    VoidCallback? onDisable,
    String? stereoLabel,
    VoidCallback? onStereo,
    String? boostLabel,
    VoidCallback? onBoost,
    bool night = false,
    ValueChanged<bool>? onNight,
  }) {
    // A row that opens a sheet of its own closes this one first.
    VoidCallback? thenClose(VoidCallback? f) => f == null
        ? null
        : () {
            Navigator.of(context).pop();
            f();
          };
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
        onDelay: thenClose(onDelay),
        disabled: disabled,
        onDisable: thenClose(onDisable),
        stereoLabel: stereoLabel,
        onStereo: thenClose(onStereo),
        boostLabel: boostLabel,
        onBoost: thenClose(onBoost),
        night: night,
        onNight: onNight,
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
            child: PlayerUi.ownLayer(PanelStepperRow(
              icon: Icons.schedule,
              label: s.pwTiming,
              value: AudioSyncSheet.format(_ms),
              onMinus: () => _set(_ms - AudioSyncSheet.step),
              onPlus: () => _set(_ms + AudioSyncSheet.step),
              onReset: () => _set(0),
              minusTooltip: s.pwDecrease(s.saDelay),
              plusTooltip: s.pwIncrease(s.saDelay),
            )),
          ),
        ),
      ],
    );
  }
}

/// A switch row that moves at once: the sheet is drawn once, the setting
/// lives in the player.
class _HeldSwitch extends StatefulWidget {
  const _HeldSwitch({
    required this.title,
    required this.initial,
    required this.onChanged,
  });

  final String title;
  final bool initial;
  final ValueChanged<bool> onChanged;

  @override
  State<_HeldSwitch> createState() => _HeldSwitchState();
}

class _HeldSwitchState extends State<_HeldSwitch> {
  late bool _on = widget.initial;

  @override
  Widget build(BuildContext context) => PanelSwitchRow(
        title: widget.title,
        value: _on,
        onChanged: (v) {
          setState(() => _on = v);
          widget.onChanged(v);
        },
      );
}

/// ♪'s Stereo mode (MX's): stereo as the film has it, mono (both sides the
/// same — one earphone), or left and right swapped.
class StereoModeSheet extends StatelessWidget {
  const StereoModeSheet({super.key, required this.mode, required this.onPick});

  final int mode;
  final ValueChanged<int> onPick;

  /// The three in words, by mode (0 stereo, 1 mono, 2 swapped).
  static String label(AppStrings s, int mode) => switch (mode) {
        1 => s.audMono,
        2 => s.audSwap,
        _ => s.audStereo,
      };

  static Future<void> show(
    BuildContext context, {
    required int mode,
    required ValueChanged<int> onPick,
  }) {
    return showPlayerSheet<void>(
      context,
      // Heard against the film: nothing over it.
      barrierColor: Colors.transparent,
      builder: (_) => StereoModeSheet(mode: mode, onPick: onPick),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerSheetHeader(title: s.audStereoMode),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(
                PlayerUi.pad(context) - 4, 2, PlayerUi.pad(context) - 4, 16),
            children: [
              for (final m in const [0, 1, 2])
                PanelRow(
                  choice: true,
                  title: label(s, m),
                  selected: m == mode,
                  onTap: () {
                    onPick(m);
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// ♪'s Volume boost: the sound above 100 %, by 10 % steps up to [max]
/// (the swipe's ceiling), a tap on the value back to 100 %. The film plays
/// behind, heard as it changes.
class AudioBoostSheet extends StatefulWidget {
  const AudioBoostSheet({
    super.key,
    required this.initialPct,
    required this.maxPct,
    required this.onChanged,
  });

  final int initialPct;
  final int maxPct;
  final ValueChanged<int> onChanged;

  static const int step = 10;

  static Future<void> show(
    BuildContext context, {
    required int initialPct,
    required int maxPct,
    required ValueChanged<int> onChanged,
  }) {
    return showPlayerSheet<void>(
      context,
      barrierColor: Colors.transparent,
      builder: (_) => AudioBoostSheet(
          initialPct: initialPct, maxPct: maxPct, onChanged: onChanged),
    );
  }

  @override
  State<AudioBoostSheet> createState() => _AudioBoostSheetState();
}

class _AudioBoostSheetState extends State<AudioBoostSheet> {
  late int _pct;

  @override
  void initState() {
    super.initState();
    _pct = widget.initialPct.clamp(100, widget.maxPct);
  }

  void _set(int v) {
    final next = v.clamp(100, widget.maxPct);
    if (next == _pct) return;
    setState(() => _pct = next);
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
          title: s.saBoost,
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
            child: PlayerUi.ownLayer(PanelStepperRow(
              icon: Icons.volume_up_rounded,
              label: s.saBoost,
              value: '$_pct %',
              onMinus: () => _set(_pct - AudioBoostSheet.step),
              onPlus: () => _set(_pct + AudioBoostSheet.step),
              onReset: () => _set(100),
              minusTooltip: s.pwDecrease(s.saBoost),
              plusTooltip: s.pwIncrease(s.saBoost),
            )),
          ),
        ),
      ],
    );
  }
}
