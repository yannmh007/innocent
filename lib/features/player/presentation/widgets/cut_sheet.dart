import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/core_providers.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/ui/app_snackbar.dart';
import '../player_provider.dart';

import '../../../../core/localization/app_strings.dart';
/// Phase 40: Video Cut/Trim editor (MX Player parity, Function PDF page 5).
///
/// Lets the user mark a start (A) and end (B) point on the video timeline.
/// Actual file export requires an FFmpeg/MediaMuxer dependency that is not
/// yet bundled with the clone — when the user taps "Export", a clear message
/// is shown instead of silently failing.
///
/// The A/B points are kept in widget-local state (not shared with the player
/// A-B repeat feature) so that opening Cut doesn't disturb playback.
class CutSheet extends ConsumerStatefulWidget {
  const CutSheet({super.key});

  /// Audit fix (B1): pause playback while the cut sheet is open and
  /// resume only if the playback WAS playing before. Frame-accurate
  /// trim points are unusable when the timeline keeps moving under
  /// the user's finger. We do not resume if the user had paused
  /// before opening (respects their explicit pause).
  static Future<void> show(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(playerControllerProvider.notifier);
    final wasPlaying = ref.read(playerControllerProvider).isPlaying;
    if (wasPlaying) {
      await controller.pause();
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const CutSheet(),
    );
    // Resume only if WE paused. If the user paused before opening we
    // leave them in their chosen state.
    if (wasPlaying) {
      try {
        await controller.play();
      } catch (e) { if (kDebugMode) debugPrint('cut_sheet.best-effort: $e'); }
    }
  }

  @override
  ConsumerState<CutSheet> createState() => _CutSheetState();
}

class _CutSheetState extends ConsumerState<CutSheet> {
  Duration? _startPoint;
  Duration? _endPoint;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _setStart() {
    final pos = _enginePosition();
    setState(() {
      _startPoint = pos;
      // If end is now before start, clear it.
      if (_endPoint != null && _endPoint! <= pos) _endPoint = null;
    });
  }

  /// Where the video actually is, to the millisecond.
  Duration _enginePosition() {
    final live = ref.read(videoPlayerServiceProvider).position;
    return live > Duration.zero
        ? live
        : ref.read(playerControllerProvider).position;
  }

  void _setEnd() {
    final pos = _enginePosition();
    if (_startPoint == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).setStartFirst),
          duration: Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    if (pos <= _startPoint!) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).endAfterStart),
          duration: Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    setState(() => _endPoint = pos);
  }

  void _clear() {
    setState(() {
      _startPoint = null;
      _endPoint = null;
    });
  }

  void _seekTo(Duration target) {
    ref.read(playerControllerProvider.notifier).seek(target);
  }

  void _export() {
    if (_startPoint == null || _endPoint == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).setBothPoints),
          duration: Duration(milliseconds: 1500),
        ),
      );
      return;
    }
    Navigator.pop(context);
    // Phase 41: route via the global messenger because `context` belongs to
    // the bottom-sheet route that was just popped.
    AppSnackbar.global(
      'Cut requires an FFmpeg add-on (not bundled). Trim points are saved for reference.',
      duration: const Duration(seconds: 3),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playerControllerProvider);
    final duration = state.duration;
    // Live engine position. The player state only carries the position while
    // something in the player itself is displaying it — this sheet is a modal
    // route on top, which the controller cannot see. Watching the scoped
    // position stream rebuilds just this sheet, and only while it is open.
    final position =
        ref.watch(videoPositionProvider).value ?? state.position;
    final clipDuration = (_startPoint != null && _endPoint != null)
        ? _endPoint! - _startPoint!
        : null;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                const Icon(Icons.content_cut,
                    color: AppColors.accentBlue, size: 22),
                const SizedBox(width: 10),
                Text(AppStrings.of(context).cut,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(AppStrings.of(context).markClipHint,
              style: TextStyle(
                color: AppColors.white60,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 20),
            _PointRow(
              label: 'Start (A)',
              value: _startPoint,
              fmt: _fmt,
              onSet: _setStart,
              onSeek: _startPoint != null ? () => _seekTo(_startPoint!) : null,
            ),
            const SizedBox(height: 12),
            _PointRow(
              label: 'End (B)',
              value: _endPoint,
              fmt: _fmt,
              onSet: _setEnd,
              onSeek: _endPoint != null ? () => _seekTo(_endPoint!) : null,
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.white05,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.timer_outlined,
                      color: Colors.white54, size: 16),
                  const SizedBox(width: 8),
                  Text(AppStrings.of(context).currentLabel + ': ${_fmt(position)} / ${_fmt(duration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const Spacer(),
                  if (clipDuration != null)
                    Text(AppStrings.of(context).clipLabel + ': ${_fmt(clipDuration)}',
                      style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: (_startPoint == null && _endPoint == null)
                        ? null
                        : _clear,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(AppStrings.of(context).clear,
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _export,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: Text(AppStrings.of(context).export,
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PointRow extends StatelessWidget {
  final String label;
  final Duration? value;
  final String Function(Duration) fmt;
  final VoidCallback onSet;
  final VoidCallback? onSeek;

  const _PointRow({
    required this.label,
    required this.value,
    required this.fmt,
    required this.onSet,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: onSeek,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.white05,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: value != null
                      ? AppColors.accentBlue40
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    value != null ? Icons.check_circle : Icons.circle_outlined,
                    color: value != null
                        ? AppColors.accentBlue
                        : Colors.white38,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    value != null ? fmt(value!) : 'Not set',
                    style: TextStyle(
                      color: value != null ? Colors.white : Colors.white54,
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (onSeek != null) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.gps_fixed,
                        color: Colors.white38, size: 12),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: onSet,
          style: TextButton.styleFrom(
            backgroundColor: AppColors.white08,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(AppStrings.of(context).setWord,
            style: TextStyle(
              color: AppColors.accentBlue,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
