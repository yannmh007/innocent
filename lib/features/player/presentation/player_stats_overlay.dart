import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/services/diagnostics/playback_log.dart';
import '../../../core/theme/app_colors.dart';
import 'player_provider.dart';

/// The overlay behind Settings → Player → Debug.
///
/// Three switches lived there — "Show buffer info", "Show decoder info",
/// "Show FPS" — each with a description, each persisted, and none of them read
/// by anything. There was no overlay for them to control.
///
/// Everything shown here comes from data the player already has, so the
/// overlay costs a subscription and nothing else:
///
///  * decoder — the strategy the user picked, plus the codec libmpv reports
///    for the stream it actually opened, which is the pair that matters when
///    you are trying to work out why a file stutters;
///  * FPS — the frame rate declared by the video track. Labelled "video FPS"
///    rather than "FPS" on purpose: this is what the file contains, not what
///    the display is managing to draw, and conflating the two is how people
///    end up chasing the wrong problem;
///  * buffer — how far ahead the demuxer has read, which is the number that
///    tells you whether a stall is the network or the decoder.
///
/// It subscribes to the buffered-position stream only while it is mounted, and
/// it is only mounted when at least one of the three switches is on.
class PlayerStatsOverlay extends ConsumerWidget {
  final bool showBuffer;
  final bool showDecoder;
  final bool showFps;

  const PlayerStatsOverlay({
    super.key,
    required this.showBuffer,
    required this.showDecoder,
    required this.showFps,
  });

  static String _fmtBitrate(int? bps) {
    if (bps == null || bps <= 0) return '';
    if (bps >= 1000000) return '${(bps / 1000000).toStringAsFixed(1)} Mbps';
    return '${(bps / 1000).toStringAsFixed(0)} kbps';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playerControllerProvider);
    final rows = <String>[];

    if (showDecoder) {
      final v = state.videoTracks.isNotEmpty ? state.videoTracks.first : null;
      final parts = <String>[state.decoder.label];
      if (v?.codec != null && v!.codec!.isNotEmpty) parts.add(v.codec!);
      if (v != null && (v.width ?? 0) > 0 && (v.height ?? 0) > 0) {
        parts.add('${v.width}×${v.height}');
      }
      final br = _fmtBitrate(v?.bitrate);
      if (br.isNotEmpty) parts.add(br);
      rows.add('DEC  ${parts.join('  ·  ')}');

      final a = state.currentAudioTrack;
      if (a != null) {
        final ap = <String>[];
        if (a.codec != null && a.codec!.isNotEmpty) ap.add(a.codec!);
        if (a.channels != null) ap.add('${a.channels}ch');
        if (a.language != null && a.language!.isNotEmpty) ap.add(a.language!);
        if (ap.isNotEmpty) rows.add('AUD  ${ap.join('  ·  ')}');
      }
    }

    if (showFps) {
      final v = state.videoTracks.isNotEmpty ? state.videoTracks.first : null;
      final fps = v?.frameRate;
      rows.add(fps != null && fps > 0
          ? 'FPS  ${fps.toStringAsFixed(2)} (video)'
          : 'FPS  —');
    }

    if (showBuffer) {
      // Only subscribed while this overlay is on screen; the provider is
      // autoDispose, so turning the switch off stops the stream entirely.
      final buffered = ref.watch(videoBufferedProvider).value;
      final ahead = buffered == null
          ? null
          : buffered - state.position;
      final aheadTxt = ahead == null
          ? '—'
          : '${(ahead.inMilliseconds / 1000).clamp(0, 99999).toStringAsFixed(1)}s ahead';
      rows.add('BUF  $aheadTxt'
          '${state.isBuffering ? '  ·  filling' : ''}');
    }

    // Background-playback trace. Shown whenever the Debug overlay is up at
    // all: the whole point of it right now is to make the screen-off moment
    // observable after the fact, and that moment is invisible by definition.
    final bg = PlaybackLog.tail(8);
    if (bg.isNotEmpty) {
      rows.add('--- background play ---');
      rows.addAll(bg);
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    return Positioned(
      left: 12,
      top: MediaQuery.of(context).padding.top + 64,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rows
                .map((t) => Text(
                      t,
                      style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 11,
                        height: 1.5,
                        fontFamily: 'monospace',
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }
}
